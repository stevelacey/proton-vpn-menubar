import AppKit
import ServiceManagement
import SystemConfiguration
import SwiftUI

struct Panel: View {
    @ObservedObject var vpn: VPN
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The row the arrow keys have moved to, which Enter picks.
    @State private var selection: ListItem?
    @State private var expanded: String?
    @State private var expandedCity: String?
    @State private var listHeight: CGFloat = 0
    @State private var titleHovered = false
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    /// Shows each button's shortcut while ⌘ is held.
    @State private var showHints = false

    var body: some View {
        Group {
            if !vpn.environment.cliInstalled {
                InstallCLI()
            } else if !vpn.accountLoaded {
                ProgressView().controlSize(.small).frame(width: 320, height: 80)
            } else if vpn.account == nil {
                SignInForm(vpn: vpn)
            } else {
                panel
            }
        }
        // The material real menus use, like other menu bar apps' panels.
        .background(MenuMaterial().ignoresSafeArea())
    }

    var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if vpn.needsSetup {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("One more step").font(.callout.weight(.semibold))
                        Text("Connecting needs root for WireGuard and the kill switch. Set up once, with your Mac's password, and it won't ask again.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Set Up…") { vpn.runSetup() }.controlSize(.small).disabled(vpn.busy != nil)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            if vpn.account?.free == true {
                QuickConnectButton(vpn: vpn).shortcutHint("↩")
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("On Proton Free, Proton picks the server. Plus adds countries, Secure Core, P2P and NetShield. ")
                        .foregroundStyle(.secondary)
                    + Text("[Upgrade](https://protonvpn.com/pricing)")
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                paidControls
            }
        }
        .padding(12)
        .frame(width: 320)
        // Up and down move through the list, as in Spotlight, from wherever focus is, which goes back
        // to the search field; Tab still moves between the controls.
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            searchFocused = true
            return move(down: press.key == .downArrow)
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow], action: expandKey)
        // While a feature's card is open, it's all you can reach, by mouse or keyboard.
        .disabled(vpn.card != nil)
        // What the panel shows changing, said out loud for VoiceOver.
        .onChange(of: vpn.status.state) { _, state in
            let place = vpn.status.country ?? vpn.status.server ?? "Proton VPN"
            let words = ["Connected": "Connected to \(place)", "Dropped": "Connection dropped",
                         "Disconnected": "Disconnected"][state]
            if let words { AccessibilityNotification.Announcement(words).post() }
        }
        .onChange(of: vpn.message) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Esc closes a feature's card even when nothing in it has focus, which needs a key to go anywhere.
                if event.keyCode == 53, vpn.card != nil {
                    vpn.card = nil
                    return nil
                }
                return command(event) ? nil : event
            }
            // Holding ⌘ on its own shows the shortcuts.
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                showHints = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                return event
            }
            // Start in the search field each time, rather than wherever macOS puts focus.
            searchFocused = true
            Task {
                await vpn.refresh()
                // The network may have changed since.
                await vpn.loadPublicIP()
            }
        }
        .task {
            while !Task.isCancelled {
                vpn.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear {
            for monitor in [keyMonitor, flagsMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
            keyMonitor = nil
            flagsMonitor = nil
            showHints = false
            vpn.card = nil
            query = ""
            selection = nil
            expanded = nil
            vpn.forgetServers()
        }
        .onExitCommand { vpn.card != nil ? (vpn.card = nil) : vpn.closePanel() }
        .overlay {
            if let card = vpn.card { FeatureCard(vpn: vpn, feature: card) }
        }
        .environment(\.shortcutHints, showHints && vpn.card == nil)
    }

    /// Everything a paid plan can choose: quick connects, features and countries.
    @ViewBuilder var paidControls: some View {
        // The buttons sit on one grid, with the same gap across and down.
        VStack(spacing: 8) {
            QuickConnectButton(vpn: vpn).shortcutHint("↩")

            HStack(spacing: 8) {
                ActionButton(title: "Fastest", symbol: "bolt.fill") { vpn.fastest() }.shortcutHint("F")
                ActionButton(title: "Random", symbol: "shuffle") { vpn.random() }.shortcutHint("R")
            }

            HStack(spacing: 8) {
                Toggle(title: "Secure Core", image: Icon.secureCore(vpn.secureCore), on: vpn.secureCore) {
                    vpn.card = .secureCore
                }
                .shortcutHint("S")
                // NetShield filters Proton's DNS, so it does nothing with another provider's.
                let netShield = vpn.settings.dns == "proton" ? vpn.settings.netshield : 0
                Toggle(title: "NetShield", image: Icon.netShield(netShield), on: netShield > 0) {
                    vpn.card = .netShield
                }
                .shortcutHint("N")
                Toggle(title: "Kill Switch", image: Icon.killSwitch(vpn.settings.killSwitch > 0),
                       on: vpn.settings.killSwitch > 0) {
                    vpn.card = .killSwitch
                }
                .shortcutHint("K")
                Toggle(title: "Port Fwd", image: Icon.portForwarding(vpn.settings.portForwarding), on: vpn.settings.portForwarding) {
                    vpn.card = .portForwarding
                }
                .shortcutHint("P")
            }
            .disabled(vpn.busy != nil)
        }

            Divider()

            countries
    }

    /// The panel's ⌘ shortcuts, the ones shown while ⌘ is held; true when it was one.
    func command(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if key == "q" {
            NSApp.terminate(nil)
            return true
        }
        guard vpn.card == nil, vpn.account != nil else { return false }
        showHints = false
        // ⌘Return presses the big button: Quick Connect, Cancel or Disconnect.
        if event.keyCode == 36 || event.keyCode == 76 {
            vpn.quickConnectOrDisconnect()
            return true
        }
        // The rest are Plus features, and wait for whatever's in progress.
        guard vpn.account?.free != true, vpn.busy == nil else { return ["f", "r", "s", "n", "k", "p"].contains(key) }
        switch key {
        case "f": vpn.fastest()
        case "r": vpn.random()
        case "s": vpn.setSecureCore(!vpn.secureCore)
        case "n": vpn.card = .netShield
        case "k": vpn.setKillSwitch(vpn.settings.killSwitch == 0)
        case "p": vpn.setPortForwarding(!vpn.settings.portForwarding)
        default: return false
        }
        return true
    }

    /// Shows or hides a country's cities and servers.
    func expand(_ c: Country, _ open: Bool) {
        expandedCity = nil
        expanded = open ? c.code : nil
        if open { Task { await vpn.loadServers(c.code) } }
    }

    /// Right and left expand and collapse the row picked with the arrows, as in Finder's list view, left on
    /// a server or city going up to its city or country, and Space toggles it, or on a server connects to
    /// it like Return. Only while a row's picked:
    /// typing clears that, so then they're the search field's again.
    func expandKey(_ press: KeyPress) -> KeyPress.Result {
        guard let selection else { return .ignored }
        let key = press.key
        switch (selection, key) {
        case (.country(let code), .rightArrow), (.country(let code), .leftArrow), (.country(let code), .space):
            guard let c = listed.first(where: { $0.code == code }) else { return .ignored }
            expand(c, key == .space ? expanded != code : key == .rightArrow)
        case (.city(_, let name), .rightArrow), (.city(_, let name), .space):
            expandedCity = key == .space && expandedCity == name ? nil : name
        case (.city(let code, let name), .leftArrow):
            if expandedCity == name { expandedCity = nil } else { self.selection = .country(code) }
        case (.server, .space):
            // Nothing to expand, so Space connects, like Return.
            choose(selection)
        case (.server(let code, let name), .leftArrow):
            let city = vpn.cities(code)?.first { $0.servers.contains { $0.name == name } }
            self.selection = (vpn.cities(code)?.count ?? 0) > 1 && city != nil ? .city(code, city!.city) : .country(code)
        default:
            return .ignored
        }
        return .handled
    }

    /// Moves the highlight down or up the list's rows, into expanded countries and cities too.
    func move(down: Bool) -> KeyPress.Result {
        let rows = navigable
        let index = selection.flatMap(rows.firstIndex(of:))
        if down {
            selection = rows.isEmpty ? nil : rows[min((index ?? -1) + 1, rows.count - 1)]
        } else {
            selection = (index ?? 0) > 0 ? rows[index! - 1] : nil
        }
        return .handled
    }

    /// A row the arrow keys can pick.
    enum ListItem: Hashable {
        case country(String)
        case city(String, String)
        case server(String, String)
    }

    /// The rows as listed, with an expanded country's cities or servers, and an expanded city's servers.
    var navigable: [ListItem] {
        listed.flatMap { c -> [ListItem] in
            var rows: [ListItem] = [.country(c.code)]
            guard expanded == c.code, let cities = vpn.cities(c.code) else { return rows }
            let servers = { (city: City) in city.servers.map { ListItem.server(c.code, $0.name) } }
            if cities.count == 1 {
                rows += servers(cities[0])
            } else {
                for city in cities {
                    rows.append(.city(c.code, city.city))
                    if expandedCity == city.city { rows += servers(city) }
                }
            }
            return rows
        }
    }

    /// Return on the picked row: connects there, or disconnects from the current country.
    func choose(_ item: ListItem) {
        switch item {
        case .country(let code):
            guard let c = listed.first(where: { $0.code == code }) else { return }
            code == vpn.activeCode ? vpn.disconnect() : vpn.connect(c)
        case .city(let code, let name):
            guard let c = listed.first(where: { $0.code == code }) else { return }
            vpn.connect(city: name, in: c, picked: true)
        case .server(let code, let name):
            guard let c = listed.first(where: { $0.code == code }),
                  let server = vpn.cities(code)?.flatMap(\.servers).first(where: { $0.name == name }) else { return }
            vpn.connect(server: server, in: c, picked: true)
        }
        query = ""
    }

    @ViewBuilder var countries: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(vpn.secureCore ? "Search Secure Core countries" : "Search countries", text: $query)
                    .focused($searchFocused)
                    .textFieldStyle(.plain)
                    // The text field takes the arrows itself before the panel would.
                    .onKeyPress(keys: [.upArrow, .downArrow]) { move(down: $0.key == .downArrow) }
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .space], action: expandKey)
                    .onSubmit {
                        if let item = selection ?? vpn.search(query).first.map({ ListItem.country($0.code) }) {
                            choose(item)
                        }
                    }
                    .onChange(of: query) { selection = nil }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).pointingHand()
                        .accessibilityLabel("Clear search")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    ForEach(filters, id: \.feature) { filter in
                        // Port forwarding only works on P2P servers, so it keeps that filter on.
                        let forced = filter.feature == "p2p" && vpn.settings.portForwarding && !vpn.secureCore
                        FilterButton(feature: filter.feature, title: filter.title, image: filter.image,
                                     tip: forced ? "P2P: required for port forwarding" : filter.tip,
                                     selected: forced || vpn.filters.contains(filter.feature), locked: forced) {
                            guard !forced else { return }
                            if vpn.filters.contains(filter.feature) {
                                vpn.filters.remove(filter.feature)
                            } else {
                                vpn.filters.insert(filter.feature)
                            }
                            // An expanded country stays open if it still matches, with its servers for the new filters.
                            if let code = expanded {
                                if listed.contains(where: { $0.code == code }) {
                                    Task { await vpn.loadServers(code) }
                                } else {
                                    expanded = nil
                                }
                            }
                        }
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.1)))
            .padding(.bottom, 4)

            let list = listed
            if list.isEmpty {
                Text(query.isEmpty && vpn.filters.isEmpty ? "No recent countries with servers for this mode" : "No countries match")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            // Scrolls once it's taller than the screen allows, and otherwise fits its rows exactly.
            ScrollViewReader { scroller in
                ScrollView {
                    // Lazy, so a country with hundreds of servers only builds the rows in sight.
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, c in
                            if index == restStart {
                                Divider().padding(.vertical, 4)
                            }
                            row(c).id(ListItem.country(c.code))
                            if expanded == c.code {
                                servers(c)
                            }
                        }
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: HeightKey.self, value: geometry.size.height)
                    })
                }
                .frame(height: min(listHeight, 300))
                .onPreferenceChange(HeightKey.self) { listHeight = $0 }
                // Keeps the row picked with the arrows in sight.
                .onChange(of: selection) { if let selection { scroller.scrollTo(selection) } }
            }
        }
    }

    @ViewBuilder func row(_ c: Country) -> some View {
        let toggle = { expand(c, expanded != c.code) }
        if c.code == vpn.activeCode {
            // The current connection stays in its place, highlighted.
            ActiveCountryRow(country: c, state: vpn.activeState, highlighted: highlighted?.code == c.code,
                             expanded: expanded == c.code, toggleExpanded: toggle,
                             pinned: vpn.pinnedCodes.contains(c.code), togglePin: { vpn.togglePin(c.code) }) {
                vpn.disconnect()
            }
        } else {
            CountryRow(country: c, highlighted: highlighted?.code == c.code,
                       pinned: vpn.pinnedCodes.contains(c.code), togglePin: { vpn.togglePin(c.code) },
                       expanded: expanded == c.code, toggleExpanded: toggle) {
                vpn.connect(c)
                query = ""
            }
        }
    }

    /// An expanded country's cities, or its servers when it only has one city.
    @ViewBuilder func servers(_ c: Country) -> some View {
        if let cities = vpn.cities(c.code) {
            if cities.isEmpty {
                Text("No servers for this mode").font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
            } else if cities.count == 1 {
                serverRows(cities[0], in: c)
            } else {
                ForEach(cities) { city in
                    CityRow(city: city, highlighted: selection == .city(c.code, city.city),
                            state: vpn.isActive(code: c.code, city: city.city) ? vpn.activeState : nil,
                            expanded: expandedCity == city.city, toggleExpanded: {
                        expandedCity = expandedCity == city.city ? nil : city.city
                    }) {
                        vpn.connect(city: city.city, in: c, picked: true)
                    }
                    .id(ListItem.city(c.code, city.city))
                    if expandedCity == city.city {
                        serverRows(city, in: c).padding(.leading, 16)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).padding(.leading, 24)
        }
    }

    @ViewBuilder func serverRows(_ city: City, in c: Country) -> some View {
        ForEach(city.servers) { server in
            ServerRow(server: server, country: c.code,
                      state: vpn.isActive(code: c.code, server: server.name) ? vpn.activeState : nil,
                      highlighted: selection == .server(c.code, server.name)) {
                vpn.connect(server: server, in: c, picked: true)
            }
            .id(ListItem.server(c.code, server.name))
        }
    }

    /// The country picked with the arrow keys, if any.
    var highlighted: Country? {
        guard case .country(let code) = selection else { return nil }
        return listed.first { $0.code == code }
    }

    var listed: [Country] { vpn.listed(query: query) }

    var restStart: Int? { vpn.restStart(query: query) }

    var filters: [(feature: String, title: String, image: Image, tip: String)] {
        [
            ("p2p", "P2P", Image(systemName: "arrow.left.arrow.right"), featureTips["p2p"]!),
            ("tor", "Tor", Image(nsImage: resource("ic-brand-tor")), featureTips["tor"]!),
            ("streaming", "streaming", Image(systemName: "play"), featureTips["streaming"]!),
        ]
    }

    /// A small DNS dropdown, like a label.
    var dnsMenu: some View {
        let current = vpn.dnsLabel
        return Menu {
            ForEach(dnsChoices, id: \.0) { choice in
                Button {
                    vpn.setDNS(choice.0)
                } label: {
                    if choice.0 == vpn.settings.dns {
                        Label(choice.1, systemImage: "checkmark")
                    } else {
                        Text(choice.1)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("DNS").foregroundStyle(.secondary)
                Text(current).fontWeight(.medium).foregroundStyle(.primary)
            }
            .font(.callout)
        }
        // A plain button style, so the label keeps the IP's size and color.
        .menuStyle(.button)
        .buttonStyle(.plain).pointingHand()
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Change DNS")
        .accessibilityLabel("DNS \(current)")
        .accessibilityHint("Changes DNS")
    }

    @ViewBuilder var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A title, the IP and DNS, then the server's load and speeds while connected.
            // Only the title shows what's in progress, so the rest stays put, e.g. while changing a setting.
            let connected = vpn.status.state == "Connected"
            if let busy = vpn.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(vpn.busyTitle(busy)).font(.title3.weight(.semibold)).lineLimit(1)
                }
                .padding(.trailing, 50)
                .titleLine()
            } else {
                switch vpn.status.state {
                case "Connected":
                    HStack(spacing: 6) {
                        Text(flag(vpn.status.code ?? "")).accessibilityHidden(true)
                        // The server's name gives way first, when it and a long country don't fit.
                        Text(vpn.status.country ?? "").fontWeight(.semibold).lineLimit(1).layoutPriority(1)
                        serverMenu
                        if let choices = vpn.serverChoices {
                            ServerShortcuts(vpn: vpn, choices: choices, hovered: titleHovered)
                        }
                    }
                    .font(.title3)
                    .onHover { titleHovered = $0 }
                    .padding(.trailing, 50)
                    .titleLine()
                    .tip(vpn.status.city ?? "")
                case "Connecting":
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to \(vpn.status.country ?? vpn.status.server ?? "Proton")…").font(.title3.weight(.semibold))
                    }
                    .padding(.trailing, 50)
                    .titleLine()
                case "Dropped":
                    Text("Connection Dropped").font(.title3.weight(.semibold)).foregroundStyle(.orange).titleLine()
                        .tip("\(vpn.status.server ?? "The server") stopped responding")
                default:
                    Text("Not Connected").font(.title3.weight(.semibold)).foregroundStyle(notConnected).titleLine()
                }
            }
            HStack(spacing: 4) {
                // The real IP until the tunnel's takes over.
                if let ip = connected ? vpn.status.ip : vpn.publicIP {
                    CopyDetail(label: "IP", value: ip).tip("Your IP address")
                }
                Spacer(minLength: 0)
                if connected, let port = vpn.status.port {
                    CopyDetail(label: "Port", value: String(port)).tip("Your forwarded port")
                    Spacer(minLength: 0)
                }
                if connected, vpn.busy == nil {
                    dnsMenu
                } else if connected {
                    // Not a menu while something's in progress, without fading like a disabled one.
                    detail("DNS", vpn.dnsLabel)
                } else {
                    detail("DNS", vpn.systemDNS)
                        .tip("Your network's DNS")
                }
            }
            .infoLine()
            // Only while connected; disconnected, the panel's that line shorter.
            if connected {
                HStack(spacing: 4) {
                    if let load = vpn.status.load {
                        HStack(spacing: 5) {
                            Text("Load").foregroundStyle(.secondary)
                            LoadBar(load: load)
                            Text("\(load)%").fontWeight(.medium).monospacedDigit()
                        }
                        .fixedSize()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Server load")
                        .accessibilityValue("\(load)%")
                    }
                    Spacer(minLength: 8)
                    if let speeds = vpn.speeds {
                        detail("↓", rate(speeds.down))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Download \(rate(speeds.down))")
                        detail("↑", rate(speeds.up)).padding(.leading, 6)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Upload \(rate(speeds.up))")
                    }
                }
                .font(.callout)
                .infoLine()
            }
            if let message = vpn.message {
                Text(message).foregroundStyle(.red).font(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(message)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                Menu {
                    if let update = vpn.update {
                        Button("Update Available: \(update.version)…") { vpn.offerUpdate() }
                        Divider()
                    }
                    if vpn.status.outdatedTools != nil {
                        // Setup copies Homebrew's newer versions, which needs your password.
                        Button("Refresh WireGuard Tools…") { vpn.runSetup() }
                        Divider()
                    }
                    if let account = vpn.account {
                        Text("\(account.username) (\(account.plan))")
                        Divider()
                    }
                    SwiftUI.Toggle("Open at Login", isOn: Binding(get: { vpn.openAtLogin }, set: { vpn.setOpenAtLogin($0) }))
                    SwiftUI.Toggle("Reconnect on Launch", isOn: $vpn.autoConnect)
                    SwiftUI.Toggle("Show Flag in Menu Bar", isOn: $vpn.showFlag)
                    Button("Keyboard Shortcuts…") {
                        vpn.card = .shortcut
                    }
                    Divider()
                    Button("Check for Updates…") { Task { await vpn.checkForUpdates(manual: true) } }
                    Button("About Proton VPN Menu Bar") { showAbout() }
                    Divider()
                    Button("Sign Out") { vpn.signOut() }
                } label: {
                    Image(systemName: "gearshape")
                        .overlay(alignment: .topTrailing) {
                            // An update is waiting.
                            if vpn.update != nil || vpn.status.outdatedTools != nil {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 2, y: -2)
                            }
                        }
                }
                .menuStyle(.button)
                .buttonStyle(.plain).pointingHand()
                .menuIndicator(.hidden)
                .fixedSize()
                .tip("Settings")
                .accessibilityLabel(vpn.update != nil || vpn.status.outdatedTools != nil ? "Settings, update available" : "Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).pointingHand()
                    .shortcutHint("Q")
                    .tip("Quit")
                    .accessibilityLabel("Quit")
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            // Centered on the title line.
            .frame(height: 24)
        }
        .padding(.horizontal, 4)
    }

    /// "IP: 1.2.3.4", as in Proton's app.
    /// The server's name, as a menu to switch to a random server in the country or one of its
    /// cities, for the current filters.
    @ViewBuilder var serverMenu: some View {
        let label = Text(vpn.status.server ?? "").foregroundStyle(.secondary).lineLimit(1)
        // Plain text when there's nothing to pick or something's in progress, not a faded menu.
        if let choices = vpn.serverChoices {
            Menu {
                Button("Fastest \(choices.country.name)") { vpn.connectFastest(choices) }
                Button("Random \(choices.country.name)") { vpn.connectRandom(choices) }
                if !choices.cities.isEmpty {
                    Divider()
                    ForEach(choices.cities, id: \.name) { city in
                        Button(city.name) { vpn.connect(city, in: choices) }
                    }
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain).pointingHand()
            .menuIndicator(.hidden)
            .tip("Change server")
            .task(id: vpn.serverListKey) { await vpn.loadCurrentServers() }
        } else {
            label.task(id: vpn.serverListKey) { await vpn.loadCurrentServers() }
        }
    }

    /// A label and its value, or nothing until the value's known.
    @ViewBuilder func detail(_ label: String, _ value: String?) -> some View {
        if let value {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Text(value).fontWeight(.medium).monospacedDigit()
            }
            .font(.callout)
            .fixedSize()
        }
    }

}



/// Behind-window blur with the menu material, which is darker than a MenuBarExtra window's own.
struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
