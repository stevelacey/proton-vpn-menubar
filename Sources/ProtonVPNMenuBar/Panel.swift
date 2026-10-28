import AppKit
import ServiceManagement
import SystemConfiguration
import SwiftUI

struct Panel: View {
    @ObservedObject var vpn: VPN
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The row the arrow keys have moved to, which Enter picks.
    @State private var selection: Int?
    @State private var expanded: String?
    @State private var expandedCity: String?
    @State private var serverLimit = serverPage
    @State private var listHeight: CGFloat = 0
    @State private var titleHovered = false

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
        // Mostly opaque: the menu bar's glass makes it hard to read over a bright window.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9).ignoresSafeArea())
    }

    var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if vpn.needsSetup {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.orange)
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
                QuickConnectButton(vpn: vpn)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
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
        .onAppear {
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
    }

    /// Everything a paid plan can choose: quick connects, features and countries.
    @ViewBuilder var paidControls: some View {
        // The buttons sit on one grid, with the same gap across and down.
        VStack(spacing: 8) {
            QuickConnectButton(vpn: vpn)

            HStack(spacing: 8) {
                ActionButton(title: "Fastest", symbol: "bolt.fill") { vpn.fastest() }
                ActionButton(title: "Random", symbol: "shuffle") { vpn.random() }
            }

            HStack(spacing: 8) {
                Toggle(title: "Secure Core", image: Icon.secureCore(vpn.secureCore), on: vpn.secureCore) {
                    vpn.card = .secureCore
                }
                // NetShield filters Proton's DNS, so it does nothing with another provider's.
                let netShield = vpn.settings.dns == "proton" ? vpn.settings.netshield : 0
                Toggle(title: "NetShield", image: Icon.netShield(netShield), on: netShield > 0) {
                    vpn.card = .netShield
                }
                Toggle(title: "Kill Switch", image: Icon.killSwitch(vpn.settings.killSwitch > 0),
                       on: vpn.settings.killSwitch > 0) {
                    vpn.card = .killSwitch
                }
                Toggle(title: "Port Fwd", image: Icon.portForwarding(vpn.settings.portForwarding), on: vpn.settings.portForwarding) {
                    vpn.card = .portForwarding
                }
            }
            .disabled(vpn.busy != nil)
        }

            Divider()

            countries
    }

    @ViewBuilder var countries: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(vpn.secureCore ? "Search Secure Core countries" : "Search countries", text: $query)
                    .focused($searchFocused)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if let country = highlighted ?? vpn.search(query).first {
                            country.code == vpn.activeCode ? vpn.disconnect() : vpn.connect(country)
                            query = ""
                        }
                    }
                    // Up and down move through the list, as in Spotlight.
                    .onKeyPress(.downArrow) {
                        selection = min((selection ?? -1) + 1, listed.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selection = (selection ?? 0) > 0 ? selection! - 1 : nil
                        return .handled
                    }
                    .onChange(of: query) { selection = nil }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).pointingHand()
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
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .padding(.bottom, 4)

            let list = listed
            if list.isEmpty {
                Text(query.isEmpty && vpn.filters.isEmpty ? "No recent countries with servers for this mode" : "No countries match")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            // Scrolls once it's taller than the screen allows, and otherwise fits its rows exactly.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, c in
                        if index == restStart {
                            Divider().padding(.vertical, 4)
                        }
                        row(c)
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
        }
    }

    @ViewBuilder func row(_ c: Country) -> some View {
        let toggle = {
            expandedCity = nil
            serverLimit = serverPage
            expanded = expanded == c.code ? nil : c.code
            if expanded != nil { Task { await vpn.loadServers(c.code) } }
        }
        if c.code == vpn.activeCode {
            // The current connection stays in its place, highlighted.
            ActiveCountryRow(country: c, state: vpn.activeState, expanded: expanded == c.code, toggleExpanded: toggle,
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
                    CityRow(city: city, expanded: expandedCity == city.city, toggleExpanded: {
                        serverLimit = serverPage
                        expandedCity = expandedCity == city.city ? nil : city.city
                    }) {
                        vpn.connect(city: city.city, in: c)
                    }
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
        let servers = city.servers
        ForEach(servers.prefix(serverLimit)) { server in
            ServerRow(server: server, country: c.code, current: vpn.status.server == server.name) {
                vpn.connect(server: server, in: c)
            }
        }
        if servers.count > serverLimit {
            Button("Show more (\(servers.count - serverLimit))") { serverLimit += serverPage }
                .buttonStyle(.plain).pointingHand()
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
                .padding(.vertical, 4)
        }
    }

    /// The row picked with the arrow keys, if any.
    var highlighted: Country? {
        guard let selection, listed.indices.contains(selection) else { return nil }
        return listed[selection]
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
                        Text(flag(vpn.status.code ?? ""))
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
                    }
                    Spacer(minLength: 8)
                    if let speeds = vpn.speeds {
                        detail("↓", rate(speeds.down))
                        detail("↑", rate(speeds.up)).padding(.leading, 6)
                    }
                }
                .font(.callout)
                .infoLine()
            }
            if let message = vpn.message {
                Text(message).foregroundStyle(.red).font(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true)
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
                    if let account = vpn.account {
                        Text("\(account.username) (\(account.plan))")
                        Divider()
                    }
                    SwiftUI.Toggle("Open at Login", isOn: Binding(get: { vpn.openAtLogin }, set: { vpn.setOpenAtLogin($0) }))
                    SwiftUI.Toggle("Reconnect on Launch", isOn: $vpn.autoConnect)
                    SwiftUI.Toggle("Show Flag in Menu Bar", isOn: $vpn.showFlag)
                    Divider()
                    Button("Check for Updates…") { Task { await vpn.checkForUpdates(manual: true) } }
                    Button("About Proton VPN Menu Bar") { showAbout() }
                    Divider()
                    Button("Sign Out") { vpn.signOut() }
                } label: {
                    Image(systemName: "gearshape")
                        .overlay(alignment: .topTrailing) {
                            // An update is waiting.
                            if vpn.update != nil {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 2, y: -2)
                            }
                        }
                }
                .menuStyle(.button)
                .buttonStyle(.plain).pointingHand()
                .menuIndicator(.hidden)
                .fixedSize()
                .tip("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).pointingHand()
                    .tip("Quit")
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

