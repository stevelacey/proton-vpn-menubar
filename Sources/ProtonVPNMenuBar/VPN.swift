import AppKit
import ServiceManagement
import SystemConfiguration
import SwiftUI

@MainActor
final class VPN: ObservableObject {
    let environment: AppEnvironment
    private var defaults: UserDefaults { environment.defaults }

    @Published var status = Status(state: "Disconnected") {
        didSet {
            animate()
            if status != oldValue { message = nil }
            if status.state == "Connected", let code = status.code {
                remember(code)
                defaults.set(code, forKey: "lastCountry")
            }
            if status.state != oldValue.state { Task { await loadPublicIP() } }
            // Done as soon as the tunnel is: Proton's CLI then spends seconds refreshing its server
            // list before it exits.
            if busy == "Disconnecting…" && status.state == "Disconnected" { busy = nil }
        }
    }
    /// The IP address sites see while disconnected, kept while connecting.
    @Published var publicIP: String?
    /// The network's DNS servers, which are in use while disconnected.
    @Published var systemDNS: String?
    /// Bytes per second down and up through the tunnel.
    @Published var speeds: (down: Double, up: Double)?
    private var lastBytes: (interface: String, down: UInt32, up: UInt32, at: Date)?
    private let store = SCDynamicStoreCreate(nil, "ProtonVPNMenuBar" as CFString, nil, nil)
    @Published var pinnedCodes: [String] {
        didSet { defaults.set(pinnedCodes, forKey: "pinned") }
    }
    @Published var recentCodes: [String] {
        didSet { defaults.set(recentCodes, forKey: "recents") }
    }
    @Published var settings = Settings()
    @Published var countries: [Country] = []
    @Published var busy: String? { didSet { animate() } }
    @Published var message: String?
    @Published var secureCore: Bool {
        didSet { defaults.set(secureCore, forKey: "secureCore") }
    }
    @Published private var frame = 0

    /// How often to check the connection, and for updates.
    var pollInterval: TimeInterval = 15
    var updateInterval: TimeInterval = 24 * 60 * 60

    private var animation: Timer?
    private var timer: Timer?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var activity: NSObjectProtocol?

    init(environment: AppEnvironment) {
        self.environment = environment
        let defaults = environment.defaults
        pinnedCodes = defaults.stringArray(forKey: "pinned") ?? []
        recentCodes = defaults.stringArray(forKey: "recents") ?? defaultRecents
        secureCore = defaults.bool(forKey: "secureCore")
        filters = Set(defaults.stringArray(forKey: "filters") ?? [])
        autoConnect = defaults.bool(forKey: "autoConnect")
        showFlag = defaults.object(forKey: "showFlag") as? Bool ?? true
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        quickShortcut = defaults.data(forKey: "quickShortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        openAtLogin = environment.loginItem.enabled
    }

    /// Starts watching the connection and settings, and loads everything.
    func start() {
        // Without this, App Nap stretches the poll below to minutes while the panel is closed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching the VPN connection")
        // Polling only catches tunnels that drop; connects and disconnects come from the watcher.
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        watch(environment.connectionDirectory)
        // Proton rewrites settings.json in place, which only the file itself reports; the folder
        // reports it being created or removed (signing out removes it), to watch the new one.
        watch(environment.settingsDirectory)
        watchSettingsFile()
        // The forwarded port, as soon as the CLI's forwarder gets one.
        watch(environment.forwardedPortDirectory)
        registerLoginItemOnce()
        // A newer release, checked on launch and then daily.
        Task { await checkForUpdates() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { await self?.checkForUpdates() }
        }
        Task {
            await loadAccount()
            await checkSetup()
            await refresh()
            await loadCountries()
            reconnectOnLaunch()
        }
    }

    /// Refreshes whenever Proton's CLI, run from anywhere, saves or removes the connection, settings or port.
    private func watch(_ directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            if directory == self?.environment.settingsDirectory { self?.watchSettingsFile() }
            Task { await self?.refresh(force: true) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers.append(source)
    }

    private var settingsWatcher: DispatchSourceFileSystemObject?

    /// Watches settings.json, if it exists, replacing the watcher on a file that's since gone.
    private func watchSettingsFile() {
        settingsWatcher?.cancel()
        settingsWatcher = nil
        let fd = open(environment.settingsDirectory + "/settings.json", O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            if source.data.contains(.delete) || source.data.contains(.rename) { self?.watchSettingsFile() }
            Task { await self?.refresh(force: true) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        settingsWatcher = source
    }

    /// Countries most recently connected to, wherever from (here or the CLI), newest first.
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

    /// A city or server picked from the list, marked there while it's the connection.
    struct Pick: Equatable {
        var code: String
        var city: String?
        var server: String?
    }

    @Published var pick: Pick?

    /// Whether a city or server is the one being connected to or connected, for its dot in the list:
    /// what was picked, as soon as it's picked, or the connection's own server and city.
    func isActive(code: String, city: String? = nil, server: String? = nil) -> Bool {
        if let pick, connectingCode != nil {
            return pick.code == code && (server.map { $0 == pick.server } ?? (pick.city == city))
        }
        guard status.state != "Disconnected", status.code == code else { return false }
        if let server { return status.server == server }
        // A city's dot is for one picked, not wherever fastest or random happened to land.
        return pick?.city == city && status.city == city
    }

    /// Adds a newly used country to the top; ones already listed stay put, so the list doesn't shuffle.
    private func remember(_ code: String) {
        guard !recentCodes.contains(code) else { return }
        recentCodes = Array(([code] + recentCodes).prefix(recentsLimit))
    }

    /// Runs `protonvpn` with these arguments, returning its exit status and output.
    func command(_ arguments: [String], started: (@Sendable (Process) -> Void)? = nil) async -> (Int32, String) {
        await runVPN(environment.vpnPath, arguments, started: started)
    }

    func refresh(force: Bool = false) async {
        guard busy == nil || force else { return }
        let (code, output) = await command(["status", "--json"])
        if code == 0, let decoded = try? JSONDecoder().decode(Status.self, from: Data(output.utf8)) {
            status = decoded
        }
        await loadSettings()
        // The server list only exists once signed in.
        if countries.isEmpty { await loadCountries() }
    }

    /// Looks up the IP address that's exposed while disconnected, with Cloudflare's trace page.
    func loadPublicIP() async {
        guard status.state == "Disconnected" else { return }
        var request = URLRequest(url: URL(string: "https://1.1.1.1/cdn-cgi/trace")!)
        request.timeoutInterval = 5
        guard let (data, _) = try? await environment.fetch(request) else { return }
        let fields = Dictionary(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            line.firstIndex(of: "=").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) }
        }, uniquingKeysWith: { a, _ in a })
        if status.state == "Disconnected", let ip = fields["ip"] {
            publicIP = ip
        }
    }

    /// Updates the speeds and the network's DNS, every second while the panel's open.
    func sample() {
        let store = store
        let global = { (key: String) in SCDynamicStoreCopyValue(store, "State:/Network/Global/\(key)" as CFString) as? [String: Any] }
        if status.state != "Connected" {
            systemDNS = (global("DNS")?["ServerAddresses"] as? [String])?.first
        }
        guard status.state == "Connected", let interface = status.interface,
              let bytes = interfaceBytes(interface) else { speeds = nil; lastBytes = nil; return }
        let now = Date()
        if let last = lastBytes, last.interface == interface {
            let seconds = now.timeIntervalSince(last.at)
            // The counters are 32-bit, so they wrap every 4 GB.
            speeds = (Double(bytes.down &- last.down) / seconds, Double(bytes.up &- last.up) / seconds)
        }
        lastBytes = (interface, bytes.down, bytes.up, now)
    }

    private func interfaceBytes(_ name: String) -> (down: UInt32, up: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var entry = list
        while let ifa = entry?.pointee {
            if ifa.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), String(cString: ifa.ifa_name) == name,
               let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                return (data.ifi_ibytes, data.ifi_obytes)
            }
            entry = ifa.ifa_next
        }
        return nil
    }

    func loadSettings() async {
        let (code, output) = await command(["settings", "--json"])
        if code == 0, let decoded = try? JSONDecoder().decode(Settings.self, from: Data(output.utf8)) {
            settings = decoded
        }
    }

    func loadCountries() async {
        let (code, output) = await command(["list", "--json"])
        if code == 0, let decoded = try? JSONDecoder().decode([Country].self, from: Data(output.utf8)) {
            countries = decoded
        }
    }

    func run(_ label: String, _ arguments: [String]) {
        guard busy == nil else { return }
        busy = label
        message = nil
        let before = status
        Task {
            let (code, output) = await command(arguments) { process in
                Task { @MainActor [weak self] in self?.running = process }
            }
            running = nil
            // Cancelled: the disconnect that cancelled it says how that went.
            if code == SIGTERM && cancelled == label {
                cancelled = nil
                return
            }
            // It may have been cleared already, once the connection changed (see status).
            if busy == label { busy = nil }
            connectingCode = nil
            let lines = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            await refresh()
            // A failure is old news if you've since connected somewhere else, e.g. from the CLI.
            let connectedSince = status.state == "Connected" && status != before
            // Red says it's an error, so without Proton's "Error: ".
            message = code == 0 || connectedSince ? nil
                : (lines.first { $0.hasPrefix("Error") } ?? lines.last ?? "Failed").replacingOccurrences(of: #"^Error:\s*"#, with: "", options: .regularExpression)
        }
    }

    /// The features the country list is filtered by (p2p, tor, streaming), kept between launches.
    @Published var filters: Set<String> {
        didSet { defaults.set(Array(filters), forKey: "filters") }
    }

    /// Secure Core, or Tor and P2P servers when filtered by those, and P2P when port forwarding is on
    /// (it only works on those).
    private var modeWords: [String] {
        if secureCore { return ["sc"] }
        var words: [String] = []
        if filters.contains("tor") { words.append("tor") }
        if filters.contains("p2p") || settings.portForwarding { words.append("p2p") }
        return words
    }

    private var mode: String? { modeWords.isEmpty ? nil : modeWords.joined(separator: " ") }


    /// Server lists by mode and country, fetched as countries are expanded, until the panel closes.
    @Published private var serverLists: [String: [City]] = [:]

    /// A country's cities, with only their servers that have every filtered feature.
    func cities(_ code: String) -> [City]? {
        serverLists["\(mode ?? "")\(code)"]?.compactMap { city in
            let servers = city.servers.filter { filters.isSubset(of: $0.features) }
            return servers.isEmpty ? nil : City(city: city.city, servers: servers)
        }
    }

    func loadServers(_ code: String) async {
        let key = "\(mode ?? "")\(code)"
        guard serverLists[key] == nil else { return }
        let (status, output) = await command(["servers"] + modeWords + [code, "--json"])
        if status == 0, let decoded = try? JSONDecoder().decode([City].self, from: Data(output.utf8)) {
            serverLists[key] = decoded
        }
    }

    /// Loads change all the time, so lists are fetched again the next time.
    func forgetServers() { serverLists = [:] }

    /// Connects to a city's fastest server; `picked` when chosen from the list, to mark it there.
    func connect(city: String, in country: Country, picked: Bool = false) {
        guard busy == nil else { return }
        connectingCode = country.code
        pick = picked ? Pick(code: country.code, city: city) : nil
        run("Connecting to \(city)…", ["city"] + modeWords + [city])
    }

    func connect(server: Server, in country: Country, picked: Bool = false) {
        guard busy == nil else { return }
        connectingCode = country.code
        pick = picked ? Pick(code: country.code, server: server.name) : nil
        run("Connecting to \(server.name)…", [server.name])
    }

    func connect(_ country: Country) {
        guard busy == nil else { return }
        connectingCode = country.code
        pick = nil
        run("Connecting to \(country.name)…", modeWords + [country.code])
    }
    func fastest() {
        pick = nil
        run("Connecting…", modeWords + ["fastest"])
    }

    func random() {
        pick = nil
        run("Connecting…", modeWords + ["random"])
    }

    /// The `protonvpn` command under way, for cancelling a connect.
    private var running: Process?
    private var cancelled: String?

    /// Disconnects, or cancels connecting by stopping that command first.
    func disconnect() {
        if let busy, busy.hasPrefix("Connecting") || busy.hasPrefix("Reconnecting"), let running {
            cancelled = busy
            running.terminate()
            self.busy = nil
            connectingCode = nil
        }
        run("Disconnecting…", ["off"])
    }

    /// Where Quick Connect goes: the last country, if it has servers for the current filters and
    /// Secure Core; otherwise the fastest server for them.
    var quickConnectCountry: Country? {
        guard account?.free != true, let code = defaults.string(forKey: "lastCountry") else { return nil }
        return available(countries).first { $0.code == code }
    }

    enum Feature { case secureCore, netShield, killSwitch, portForwarding, shortcut }

    /// The feature whose card is open in the panel, to choose its setting.
    @Published var card: Feature?

    func setSecureCore(_ on: Bool) {
        secureCore = on
    }

    func quickConnect() {
        if let country = quickConnectCountry { connect(country) } else { fastest() }
    }

    /// What the big button does: Quick Connect, Cancel while connecting, or Disconnect.
    func quickConnectOrDisconnect() {
        switch activeState {
        case "Disconnected": if busy == nil { quickConnect() }
        case "Connecting": disconnect()
        default: if busy == nil { disconnect() }
        }
    }
    func signOut() {
        guard busy == nil else { return }
        busy = "Signing out…"
        Task {
            _ = await command(["signout"])
            busy = nil
            await loadAccount()
            await refresh()
        }
    }

    /// A newer release on GitHub, if there is one.
    @Published var update: (version: String, url: URL)?
    private var updateTimer: Timer?

    /// Shows a message, or that an update is available (`update`); the app shows them as alerts.
    var onAlert: (_ title: String, _ text: String) -> Void = { _, _ in }
    var onUpdateAvailable: () -> Void = {}

    /// Checks GitHub for a newer release; asked for from the menu, it also says when there isn't one.
    func checkForUpdates(manual: Bool = false) async {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/stevelacey/proton-vpn-menubar/releases/latest")!)
        request.timeoutInterval = 10
        struct Release: Decodable { let tag_name: String; let html_url: URL }
        guard let (data, response) = try? await environment.fetch(request) else {
            if manual { onAlert("Couldn't check for updates", "GitHub didn't answer. Try again later.") }
            return
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            // No releases yet (a 404) means this is the latest.
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                if manual { onAlert("You're up to date", "Proton VPN Menu Bar \(environment.version) is the latest version.") }
                return
            }
            if manual { onAlert("Couldn't check for updates", "GitHub didn't answer. Try again later.") }
            return
        }
        let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        if latest.compare(environment.version, options: .numeric) == .orderedDescending {
            update = (latest, release.html_url)
            if manual { onUpdateAvailable() }
        } else {
            update = nil
            if manual { onAlert("You're up to date", "Proton VPN Menu Bar \(environment.version) is the latest version.") }
        }
    }

    /// Connects again to the last country on launch, when disconnected.
    @Published var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: "autoConnect") }
    }

    /// The shortcut that opens and closes the panel from any app, if you've set one.
    @Published var shortcut: Shortcut? {
        didSet {
            defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut")
            onShortcutChange()
        }
    }

    /// The shortcut that quick connects, or disconnects, from any app, if you've set one.
    @Published var quickShortcut: Shortcut? {
        didSet {
            defaults.set(try? JSONEncoder().encode(quickShortcut), forKey: "quickShortcut")
            onShortcutChange()
        }
    }

    /// Registers the shortcuts with macOS; the app's, and nothing in tests.
    var onShortcutChange: () -> Void = {}

    @Published var showFlag: Bool {
        didSet { defaults.set(showFlag, forKey: "showFlag") }
    }

    @Published var openAtLogin: Bool

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try environment.loginItem.register() } else { try environment.loginItem.unregister() }
        } catch {
            message = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        openAtLogin = environment.loginItem.enabled
    }

    /// Opens at login by default, the first time the app runs.
    private func registerLoginItemOnce() {
        guard !defaults.bool(forKey: "loginItemRegistered") else { return }
        defaults.set(true, forKey: "loginItemRegistered")
        setOpenAtLogin(true)
    }

    private func reconnectOnLaunch() {
        guard autoConnect, account != nil, status.state == "Disconnected" else { return }
        quickConnect()
    }

    /// Whether `protonvpn setup` still has to run, so connecting works without a password.
    @Published var needsSetup = false

    func checkSetup() async {
        let (code, _) = await command(["setup", "--check"])
        needsSetup = code != 0
    }

    /// Runs `protonvpn setup` as root, with macOS asking for an administrator's password.
    func runSetup() {
        let command = "'\(environment.vpnPath)' setup --user \(NSUserName())"
        busy = "Setting up…"
        Task {
            let (status, output) = await environment.runAsAdministrator(command)
            busy = nil
            if !status, !output.contains("User canceled") { message = output }
            await checkSetup()
        }
    }

    /// The signed-in account; nil when signed out, once known.
    @Published var account: Account?
    @Published var accountLoaded = false
    @Published var signIn = SignIn.form
    @Published var signInError: String?
    private var signInProcess: Process?
    private var signInInput: FileHandle?

    func loadAccount() async {
        let (code, output) = await command(["account", "--json"])
        // Keeps the last known account if the CLI fails, rather than showing the sign-in form.
        if code == 0 {
            account = try? JSONDecoder().decode(Account.self, from: Data(output.utf8))
        }
        accountLoaded = true
    }

    /// Signs in through `protonvpn signin --stdin`, which answers Proton's own prompts from what's typed here.
    func signIn(username: String, password: String) {
        guard signInProcess == nil else { return }
        signIn = .working
        signInError = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment.vpnPath)
        process.arguments = ["signin", "--stdin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            for line in buffer.append(data) {
                Task { @MainActor [weak self] in self?.signInReplied(line) }
            }
        }
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.signInProcess = nil
                self.signInInput = nil
                if self.signIn != .form { self.signIn = .form }
            }
        }
        do {
            try process.run()
        } catch {
            signIn = .form
            signInError = "Couldn't run \(environment.vpnPath)"
            return
        }
        signInProcess = process
        signInInput = input.fileHandleForWriting
        signInInput?.write(Data("\(username)\n\(password)\n".utf8))
    }

    func submit(code: String) {
        signIn = .working
        signInInput?.write(Data("\(code)\n".utf8))
    }

    func cancelSignIn() {
        signInProcess?.terminate()
        signIn = .form
    }

    private func signInReplied(_ line: String) {
        if line == "2fa" || line == "2fa invalid" {
            signIn = .code(invalid: line == "2fa invalid")
        } else if line.hasPrefix("ok ") {
            signIn = .form
            Task {
                await loadAccount()
                await refresh(force: true)
                await loadCountries()
            }
        } else if line.hasPrefix("error ") {
            signIn = .form
            signInError = String(line.dropFirst(6))
        }
    }

    func setNetShield(_ level: Int) {
        guard level != settings.netshield, let name = NetShieldLevel.all.first(where: { $0.level == level }) else { return }
        // Short enough for the title, which the card already says the level beside.
        run(level == 0 ? "Turning NetShield off…" : "Updating NetShield…", ["set", "netshield", name.value])
    }

    func setKillSwitch(_ on: Bool) {
        guard on != (settings.killSwitch > 0) else { return }
        run("Turning the kill switch \(on ? "on" : "off")…", ["set", "kill-switch", on ? "standard" : "off"])
    }

    func setDNS(_ choice: String) {
        guard choice != settings.dns else { return }
        let label = dnsChoices.first { $0.0 == choice }?.1 ?? choice
        run("Switching to \(label) DNS…", ["dns", choice])
    }

    func setPortForwarding(_ on: Bool) {
        guard on != settings.portForwarding else { return }
        run("Turning port forwarding \(on ? "on" : "off")…", ["set", "port-forwarding", on ? "on" : "off"])
    }

    /// Countries that have servers for the current mode.
    func available(_ list: [Country]) -> [Country] {
        if secureCore { return list.filter { $0.features.contains("securecore") } }
        // Port forwarding only works on P2P servers, so it's one more feature to have.
        let required = settings.portForwarding ? filters.union(["p2p"]) : filters
        if !required.isEmpty { return list.filter { $0.hasServer(with: required) } }
        return list
    }

    /// Recent countries, all countries with the filtered features, or search results while typing.
    func listed(query: String) -> [Country] {
        if !query.isEmpty { return Array(search(query).prefix(10)) }
        if !filters.isEmpty {
            let usual = available(recents)
            let rest = available(countries).filter { c in !usual.contains { $0.code == c.code } }
            return usual + rest.sorted { $0.name < $1.name }
        }
        return available(recents)
    }

    /// While filtering, where the rest of the countries start, after your pinned and recent ones
    /// that match, and a divider.
    func restStart(query: String) -> Int? {
        guard query.isEmpty, !filters.isEmpty else { return nil }
        let count = available(recents).count
        return count > 0 && count < listed(query: query).count ? count : nil
    }

    /// The chosen DNS's name.
    var dnsLabel: String { dnsChoices.first { $0.0 == settings.dns }?.1 ?? "Custom" }

    /// What's in progress, saying where it's connecting to once Proton's picked a server, e.g. for
    /// Fastest or Random.
    func busyTitle(_ busy: String) -> String {
        // Only for fastest and random, which don't say where; a city or server keeps its own name.
        guard busy == "Connecting…" || busy == "Reconnecting…", status.state == "Connecting",
              let country = status.country else { return busy }
        return "Connecting to \(country)…"
    }

    /// Other servers to switch to in the connected country, for the current filters: the fastest or
    /// a random one, and, when it has more than one city, a random other one in your city or the
    /// fastest in another.
    struct ServerChoices {
        var country: Country
        var others: [Server]
        /// Each city's random other servers, or nil to go to its fastest.
        var cities: [(name: String, servers: [Server]?)]
    }

    var serverChoices: ServerChoices? {
        let current = status.server ?? ""
        // Proton Free connects to the server Proton picks, so there's nothing to switch to.
        guard busy == nil, account?.free != true, let code = status.code, let country = countries.first(where: { $0.code == code }),
              let cities = cities(code) else { return nil }
        let others = cities.flatMap(\.servers).filter { $0.name != current }
        guard !others.isEmpty else { return nil }
        let choices: [(name: String, servers: [Server]?)] = cities.count < 2 ? [] : cities.compactMap { city in
            let servers = city.servers.filter { $0.name != current }
            if !city.servers.contains(where: { $0.name == current }) { return (city.city, nil) }
            return servers.isEmpty ? nil : (city.city, servers)
        }
        return ServerChoices(country: country, others: others, cities: choices)
    }

    func connectFastest(_ choices: ServerChoices) {
        connect(server: choices.others.min { $0.load < $1.load }!, in: choices.country)
    }

    func connectRandom(_ choices: ServerChoices) {
        connect(server: choices.others.randomElement()!, in: choices.country)
    }

    func connect(_ city: (name: String, servers: [Server]?), in choices: ServerChoices) {
        if let servers = city.servers {
            connect(server: servers.randomElement()!, in: choices.country)
        } else {
            connect(city: city.name, in: choices.country)
        }
    }

    /// The connected country's servers, loaded again when the filters change.
    var serverListKey: String { "\(status.code ?? "")\(filters.sorted())\(settings.portForwarding)\(secureCore)" }

    func loadCurrentServers() async {
        if let code = status.code { await loadServers(code) }
    }

    /// Same ranking as `protonvpn list`: code, name or alias, then prefixes, then substrings.
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

    var connecting: Bool { (busy?.hasPrefix("Connecting") ?? false) || status.state == "Connecting" }

    /// Animates the icon while connecting, whether from here or the CLI.
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
        if status.state == "Dropped" || (message != nil && status.state != "Connected") { return MenuBarIcon.error }
        if showFlag, status.state == "Connected", let code = status.code { return MenuBarIcon.flagged(code) }
        return status.state == "Connected" ? MenuBarIcon.connected : MenuBarIcon.disconnected
    }
}

