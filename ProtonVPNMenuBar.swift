// Proton VPN in the menu bar: status, quick actions and a country search, all through the `vpn` CLI.
import AppKit
import SwiftUI

let vpnPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Sites/proton/.venv/bin/vpn").path

let connectionDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/Proton/VPN/connection").path

let settingsDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/Proton/VPN").path

/// DNS choices, as `vpn dns` names and labels.
let dnsChoices: [(String, String)] = [
    ("proton", "Proton"), ("cloudflare", "Cloudflare"), ("google", "Google"),
    ("opendns", "OpenDNS"), ("quad9", "Quad9"),
]

/// Proton's pinkish red for "Not Connected".
let notConnected = Color(red: 0.91, green: 0.42, blue: 0.47)

/// Shown until there are recent countries to replace them.
let defaultRecents = ["CH", "UK", "US", "DE"]
let recentsLimit = 6

struct Status: Decodable, Equatable {
    var state: String
    var server: String?
    var code: String?
    var country: String?
    var city: String?
    var ip: String?
    var port: Int?
}

struct Settings: Decodable, Equatable {
    var netshield = 1
    var killSwitch = 0
    var portForwarding = false
    var dns = "proton"

    enum CodingKeys: String, CodingKey {
        case netshield, killSwitch = "kill_switch", portForwarding = "port_forwarding", dns
    }
}

struct Country: Decodable, Identifiable, Equatable {
    var code: String
    var name: String
    var servers: Int
    var aliases: [String]
    var features: [String]
    var id: String { code }
}

/// Runs `vpn` with the given arguments, returning its exit status and output.
func runVPN(_ arguments: [String]) async -> (Int32, String) {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: vpnPath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, "Couldn't run \(vpnPath): \(error.localizedDescription)"))
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
        }
    }
}

/// Proton uses UK where the regional indicators (and ISO) use GB.
func flag(_ code: String) -> String {
    let iso = code == "UK" ? "GB" : code
    return String(String.UnicodeScalarView(iso.unicodeScalars.compactMap { Unicode.Scalar(127397 + $0.value) }))
}

func fold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
}

/// An image from the app's Resources, taken from Proton's app.
func resource(_ name: String, template: Bool = true) -> NSImage {
    let url = Bundle.main.url(forResource: name, withExtension: "pdf")
        ?? Bundle.main.url(forResource: name, withExtension: "png")
    let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    image.isTemplate = template
    return image
}

/// Proton's menu bar icons, sized for the menu bar.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    static let connected = sized(resource("connected"))
    static let disconnected = sized(resource("disconnected"))

    /// Proton's icon with its badge replaced by three dots, one of them highlighted.
    static let connecting: [NSImage] = (0..<3).map { highlighted in
        let image = NSImage(size: size, flipped: false) { rect in
            resource("disconnected").draw(in: rect)
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            // The badge is a circle in the icon's top right corner (in 36pt units: centre 25.2, 25.6; radius 9.8).
            let scale = rect.width / 36
            let center = CGPoint(x: 25.2 * scale, y: 25.6 * scale)
            let radius = 9.8 * scale
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.setBlendMode(.destinationOut)
            for dot in 0..<3 {
                let r = (dot == highlighted ? 2.1 : 1.3) * scale
                let x = center.x + CGFloat(dot - 1) * 5.4 * scale
                context.fillEllipse(in: CGRect(x: x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func sized(_ image: NSImage) -> NSImage {
        image.size = size
        return image
    }
}

@MainActor
final class VPN: ObservableObject {
    @Published var status = Status(state: "Disconnected") {
        didSet {
            animate()
            if status != oldValue { message = nil }
            keepPortForwarded()
            if status.state == "Connected", let code = status.code { remember(code) }
            if status.state != oldValue.state { Task { await loadPublicIP() } }
        }
    }
    /// The IP address sites see while disconnected.
    @Published var publicIP: String?
    @Published var pinnedCodes = UserDefaults.standard.stringArray(forKey: "pinned") ?? [] {
        didSet { UserDefaults.standard.set(pinnedCodes, forKey: "pinned") }
    }
    @Published var recentCodes = UserDefaults.standard.stringArray(forKey: "recents") ?? defaultRecents {
        didSet { UserDefaults.standard.set(recentCodes, forKey: "recents") }
    }
    @Published var settings = Settings() { didSet { keepPortForwarded() } }
    private var forwarder: Process?
    @Published var countries: [Country] = []
    @Published var busy: String? { didSet { animate() } }
    @Published var message: String?
    @Published var secureCore = UserDefaults.standard.bool(forKey: "secureCore") {
        didSet { UserDefaults.standard.set(secureCore, forKey: "secureCore") }
    }
    @Published private var frame = 0

    private var animation: Timer?
    private var timer: Timer?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var activity: NSObjectProtocol?

    init() {
        // Without this, App Nap stretches the poll below to minutes while the panel is closed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching the VPN connection")
        // Polling only catches tunnels that drop; connects and disconnects come from the watcher.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        watch(connectionDirectory)
        // Proton rewrites settings.json in place, which only the file itself reports.
        watch(settingsDirectory + "/settings.json")
        Task {
            await refresh()
            await loadCountries()
        }
    }

    /// Refreshes whenever Proton's CLI, run from anywhere, saves or removes the connection or settings.
    private func watch(_ directory: String) {
        if !directory.hasSuffix(".json") {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { await self?.refresh(force: true) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers.append(source)
    }

    /// Countries most recently connected to, wherever from (here, the CLI or Alfred), newest first.
    /// Pinned countries, then recent ones.
    var recents: [Country] {
        (pinnedCodes + recentCodes.filter { !pinnedCodes.contains($0) })
            .compactMap { code in countries.first { $0.code == code } }
    }

    func togglePin(_ code: String) {
        if pinnedCodes.contains(code) {
            pinnedCodes.removeAll { $0 == code }
        } else {
            pinnedCodes.append(code)
        }
    }

    /// The country being connected to from here, before the CLI has reported anything.
    @Published var connectingCode: String?

    /// The country of the current connection, whether connected, connecting or dropped.
    var activeCode: String? {
        if let connectingCode { return connectingCode }
        guard status.state != "Disconnected" else { return nil }
        if let code = status.code { return code }
        // Connecting from elsewhere only reports the server, e.g. CH#871, or IS-CH#1 via Secure Core.
        return status.server?.split(separator: "#").first?.split(separator: "-").last.map(String.init)
    }

    var activeState: String { connectingCode != nil ? "Connecting" : status.state }

    /// Adds a newly used country to the top; ones already listed stay put, so the list doesn't shuffle.
    private func remember(_ code: String) {
        guard !recentCodes.contains(code) else { return }
        recentCodes = Array(([code] + recentCodes).prefix(recentsLimit))
    }

    func refresh(force: Bool = false) async {
        guard busy == nil || force else { return }
        let (code, output) = await runVPN(["status", "--json"])
        if code == 0, let decoded = try? JSONDecoder().decode(Status.self, from: Data(output.utf8)) {
            status = decoded
        }
        await loadSettings()
        // The server list only exists once signed in.
        if countries.isEmpty { await loadCountries() }
    }

    /// Looks up the IP address that's exposed while disconnected, with Cloudflare's trace page.
    func loadPublicIP() async {
        guard status.state == "Disconnected" else { publicIP = nil; return }
        var request = URLRequest(url: URL(string: "https://1.1.1.1/cdn-cgi/trace")!)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
        let ip = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("ip=") }?.dropFirst(3)
        if status.state == "Disconnected", let ip { publicIP = String(ip) }
    }

    func loadSettings() async {
        let (code, output) = await runVPN(["settings", "--json"])
        if code == 0, let decoded = try? JSONDecoder().decode(Settings.self, from: Data(output.utf8)) {
            settings = decoded
        }
    }

    func loadCountries() async {
        let (code, output) = await runVPN(["list", "--json"])
        if code == 0, let decoded = try? JSONDecoder().decode([Country].self, from: Data(output.utf8)) {
            countries = decoded
        }
    }

    func run(_ label: String, _ arguments: [String]) {
        guard busy == nil else { return }
        busy = label
        message = nil
        Task {
            let (code, output) = await runVPN(arguments)
            busy = nil
            connectingCode = nil
            let lines = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            await refresh()
            message = code == 0 ? nil : (lines.first { $0.hasPrefix("Error") } ?? lines.last ?? "Failed")
        }
    }

    /// Secure Core, or P2P servers when port forwarding is on (it only works on those).
    private var modeWords: [String] {
        secureCore ? ["sc"] : settings.portForwarding ? ["p2p"] : []
    }

    private var modeLabel: String {
        secureCore ? " via Secure Core" : settings.portForwarding ? " (P2P)" : ""
    }

    func connect(_ country: Country) {
        guard busy == nil else { return }
        connectingCode = country.code
        run("Connecting to \(country.name)\(modeLabel)…", modeWords + [country.code])
    }
    func fastest() { run("Connecting to the fastest server\(modeLabel)…", modeWords + ["fastest"]) }
    func random() { run("Connecting to a random server\(modeLabel)…", modeWords + ["random"]) }
    func disconnect() { run("Disconnecting…", ["off"]) }
    func signOut() { run("Signing out…", ["signout"]) }

    func toggleNetShield() {
        let on = settings.netshield == 0
        run("Turning NetShield \(on ? "on" : "off")…", ["set", "netshield", on ? "malware-ads-trackers" : "off"])
    }

    func toggleKillSwitch() {
        let on = settings.killSwitch == 0
        run("Turning the kill switch \(on ? "on" : "off")…", ["set", "kill-switch", on ? "standard" : "off"])
    }

    func setDNS(_ choice: String) {
        guard choice != settings.dns else { return }
        let label = dnsChoices.first { $0.0 == choice }?.1 ?? choice
        run("Switching DNS to \(label)…", ["dns", choice])
    }

    func togglePortForwarding() {
        let on = !settings.portForwarding
        run("Turning port forwarding \(on ? "on" : "off")…", ["set", "port-forwarding", on ? "on" : "off"])
    }

    /// Countries that have servers for the current mode.
    func available(_ list: [Country]) -> [Country] {
        if secureCore { return list.filter { $0.features.contains("securecore") } }
        if settings.portForwarding { return list.filter { $0.features.contains("p2p") } }
        return list
    }

    /// Same ranking as `vpn list`: code, name or alias, then prefixes, then substrings.
    func search(_ query: String) -> [Country] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        let ranked: [(Int, Country)] = available(countries).compactMap { c in
            let name = fold(c.name)
            let words = name.split(whereSeparator: { " -&".contains($0) })
            if q == c.code.lowercased() || q == name || c.aliases.contains(q) { return (0, c) }
            if name.hasPrefix(q) || c.aliases.contains(where: { $0.hasPrefix(q) }) { return (1, c) }
            if words.contains(where: { $0.hasPrefix(q) }) { return (2, c) }
            if name.contains(q) { return (3, c) }
            return nil
        }
        return ranked.sorted { ($0.0, $0.1.name) < ($1.0, $1.1.name) }.map(\.1)
    }

    /// Runs `vpn forward` while connected with port forwarding on, which renews the port
    /// Proton's server only hands out for a minute at a time.
    private func keepPortForwarded() {
        let wanted = status.state == "Connected" && settings.portForwarding
        if wanted, forwarder?.isRunning != true {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: vpnPath)
            process.arguments = ["forward"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                Task { @MainActor [weak self] in await self?.refresh(force: true) }
            }
            try? process.run()
            forwarder = process
        } else if !wanted, let process = forwarder {
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            forwarder = nil
        }
    }

    var connecting: Bool { (busy?.hasPrefix("Connecting") ?? false) || status.state == "Connecting" }

    /// Animates the icon while connecting, whether from here, the CLI or Alfred.
    private func animate() {
        if connecting, animation == nil {
            animation = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.frame += 1 }
            }
        } else if !connecting {
            animation?.invalidate()
            animation = nil
        }
    }

    var icon: NSImage {
        if connecting { return MenuBarIcon.connecting[frame % 3] }
        return status.state == "Connected" ? MenuBarIcon.connected : MenuBarIcon.disconnected
    }
}

/// A full-width row that highlights on hover, like a menu item.
struct HoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct FeatureIcons: View {
    let features: [String]

    var body: some View {
        HStack(spacing: 5) {
            if features.contains("p2p") { Image(systemName: "arrow.left.arrow.right").help("P2P") }
            if features.contains("tor") { Image(nsImage: resource("ic-brand-tor")).resizable().frame(width: 12, height: 12).help("Tor") }
            if features.contains("streaming") { Image(systemName: "play").help("Streaming") }
            if features.contains("smartrouting") { Image(systemName: "globe").help("Smart routing") }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
}

struct CountryRow: View {
    let country: Country
    let pinned: Bool
    let togglePin: () -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HoverButton(action: action) {
            HStack(spacing: 8) {
                Text(flag(country.code))
                Text(country.name)
                Spacer()
                FeatureIcons(features: country.features)
                PinButton(pinned: pinned, visible: hovering, action: togglePin)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A star that pins a country to the top of the list: always shown once pinned, otherwise on hover.
struct PinButton: View {
    let pinned: Bool
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: pinned ? "star.fill" : "star")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 12)
        }
        .buttonStyle(.plain)
        .opacity(pinned || visible ? 1 : 0)
        .help(pinned ? "Unpin" : "Pin to the top")
    }
}

/// The country connected to (or connecting or dropped), tinted by state, with the Disconnect button.
struct ActiveCountryRow: View {
    let country: Country
    let state: String
    let disconnect: () -> Void
    @State private var hovering = false

    var tint: Color {
        switch state {
        case "Connected": return .green
        case "Dropped": return .orange
        default: return .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(flag(country.code))
            Text(country.name).fontWeight(.semibold)
            Spacer()
            FeatureIcons(features: country.features)
            Button(action: disconnect) {
                Text(state == "Connecting" ? "Cancel" : "Disconnect")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(hovering ? 0.25 : 0.14)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            if state == "Connecting" {
                // Pulses while connecting.
                TimelineView(.animation) { timeline in
                    let pulse = (sin(timeline.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
                    RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.1 + 0.25 * pulse))
                }
            } else {
                RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.18))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.45)))
    }
}

/// One of the quick settings, like the four in Proton's app.
struct Toggle: View {
    let title: String
    let image: Image
    let on: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text(title).font(.system(size: 10))
            }
            .foregroundStyle(on ? Color.white : enabled ? Color.primary : Color.secondary.opacity(0.6))
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(on ? Color.accentColor : Color.primary.opacity(hovering ? 0.12 : 0.06))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && enabled }
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Panel: View {
    @ObservedObject var vpn: VPN
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            HStack(spacing: 8) {
                ActionButton(title: "Fastest", symbol: "bolt.fill") { vpn.fastest() }
                ActionButton(title: "Random", symbol: "shuffle") { vpn.random() }
            }

            HStack(spacing: 6) {
                Toggle(title: "Secure Core", image: Image(nsImage: resource("ic-lock")), on: vpn.secureCore) {
                    vpn.secureCore.toggle()
                }
                // NetShield filters Proton's DNS, so it does nothing with another provider's.
                Toggle(title: "NetShield", image: Image(nsImage: resource("ic-shield")),
                       on: vpn.settings.netshield > 0 && vpn.settings.dns == "proton") {
                    vpn.toggleNetShield()
                }
                .disabled(vpn.settings.dns != "proton")
                .overlay {
                    // Disabled buttons show no tooltip, so it goes on a layer above.
                    if vpn.settings.dns != "proton" {
                        Color.clear.contentShape(Rectangle()).help("NetShield only works with Proton's DNS")
                    }
                }
                Toggle(title: "Kill Switch", image: Image(nsImage: resource("ic-killswitch")), on: vpn.settings.killSwitch > 0) {
                    vpn.toggleKillSwitch()
                }
                Toggle(title: "Port Fwd", image: Image(systemName: "arrow.right.to.line"), on: vpn.settings.portForwarding) {
                    vpn.togglePortForwarding()
                }
            }
            .disabled(vpn.busy != nil)


            Divider()

            countries
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            Task {
                await vpn.refresh()
                // The network may have changed since.
                await vpn.loadPublicIP()
            }
        }
        .onDisappear { query = "" }
    }

    @ViewBuilder var countries: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(vpn.secureCore ? "Search Secure Core countries" : "Search countries", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if let first = vpn.search(query).first {
                            vpn.connect(first)
                            query = ""
                        }
                    }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .padding(.bottom, 4)

            let list = listed
            if list.isEmpty {
                Text(query.isEmpty ? "No recent countries with servers for this mode" : "No countries match")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            // Plain rows rather than a scroll view, so the panel grows to fit them.
            ForEach(list) { c in
                if c.code == vpn.activeCode {
                    // The current connection stays in its place, highlighted, with the Disconnect button.
                    ActiveCountryRow(country: c, state: vpn.activeState) { vpn.disconnect() }
                } else {
                CountryRow(country: c, pinned: vpn.pinnedCodes.contains(c.code), togglePin: { vpn.togglePin(c.code) }) {
                    vpn.connect(c)
                    query = ""
                }
                }
            }
        }
    }

    /// Recent countries, or search results while typing.
    var listed: [Country] {
        query.isEmpty ? vpn.available(vpn.recents) : Array(vpn.search(query).prefix(10))
    }

    /// A small DNS dropdown, like a label.
    var dnsMenu: some View {
        let current = dnsChoices.first { $0.0 == vpn.settings.dns }?.1 ?? "Custom"
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
            HStack(spacing: 2) {
                Text("DNS: \(current)")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        // A plain button style, so the label keeps the IP's size and color.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(vpn.busy != nil)
    }

    @ViewBuilder var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let busy = vpn.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.headline).lineLimit(2)
                }
            } else {
                switch vpn.status.state {
                case "Connected":
                    HStack(spacing: 6) {
                        Text(flag(vpn.status.code ?? ""))
                        Text(vpn.status.country ?? "").fontWeight(.semibold)
                        Text(vpn.status.server ?? "").foregroundStyle(.secondary)
                    }
                    .font(.title3)
                    .help(vpn.status.city ?? "")
                    HStack(spacing: 4) {
                        ipLabel(vpn.status.ip)
                        Spacer()
                        dnsMenu
                    }
                    if let port = vpn.status.port {
                        HStack(spacing: 4) {
                            Text("Forwarded port:").foregroundStyle(.secondary)
                            Text(String(port)).fontWeight(.semibold).textSelection(.enabled)
                        }
                        .font(.callout)
                    }
                case "Connecting":
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to \(vpn.status.server ?? "")…").font(.headline)
                    }
                case "Dropped":
                    Text("Connection Dropped").font(.title3.weight(.semibold)).foregroundStyle(.orange)
                    Text("\(vpn.status.server ?? "The server") stopped responding").font(.callout).foregroundStyle(.secondary)
                default:
                    Text("Not Connected").font(.title3.weight(.semibold)).foregroundStyle(notConnected)
                    // DNS only applies to the tunnel, so there's nothing to pick while disconnected.
                    ipLabel(vpn.publicIP)
                }
            }
            if let message = vpn.message {
                Text(message).foregroundStyle(.red).font(.caption).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 44)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                // Normally on the country's row, unless the row isn't listed (e.g. while searching).
                if vpn.status.state != "Disconnected" && vpn.busy == nil && !listed.contains(where: { $0.code == vpn.activeCode }) {
                    Button("Disconnect") { vpn.disconnect() }
                        .controlSize(.small)
                        .focusable(false)
                }
                Menu {
                    Button("Sign Out") { vpn.signOut() }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Account")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain)
                    .help("Quit")
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    /// "IP: 1.2.3.4", as in Proton's app.
    func ipLabel(_ ip: String?) -> some View {
        HStack(spacing: 4) {
            Text("IP:").foregroundStyle(.secondary)
            Text(ip ?? "…").fontWeight(.semibold).textSelection(.enabled)
        }
        .font(.callout)
    }
}

@main
struct ProtonVPNMenuBar: App {
    @StateObject private var vpn = VPN()

    var body: some Scene {
        MenuBarExtra {
            Panel(vpn: vpn)
        } label: {
            Image(nsImage: vpn.icon)
        }
        .menuBarExtraStyle(.window)
    }
}
