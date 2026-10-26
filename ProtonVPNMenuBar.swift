// Proton VPN in the menu bar: status, quick actions and a country search, all through the `vpn` CLI.
import AppKit
import ServiceManagement
import SwiftUI

/// The `vpn` command from proton-vpn-cli-macos, wherever Homebrew, uv or pipx put it.
let vpnPath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [UserDefaults.standard.string(forKey: "vpnPath"), "/opt/homebrew/bin/vpn",
                      "/usr/local/bin/vpn", "\(home)/.local/bin/vpn"].compactMap { $0 }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[1]
}()

let cliInstalled = FileManager.default.isExecutableFile(atPath: vpnPath)

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

/// How many of a city's servers to show at a time, least loaded first.
let serverPage = 8

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

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

struct Account: Decodable, Equatable {
    var username: String
    var plan: String
    var tier: Int?

    /// Proton Free, which connects to the fastest free server only.
    var free: Bool { tier == 0 }
}

/// Splits a process's output into lines as it arrives.
final class LineBuffer: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        text += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let newline = text.firstIndex(of: "\n") {
            lines.append(String(text[..<newline]))
            text.removeSubrange(...newline)
        }
        return lines
    }
}

/// Where signing in from the panel is up to.
enum SignIn: Equatable {
    case form
    case working
    case code(invalid: Bool)
}

struct Country: Decodable, Identifiable, Equatable {
    var code: String
    var name: String
    var servers: Int
    var aliases: [String]
    var features: [String]
    /// The feature combinations its servers have, e.g. [["p2p", "streaming"], ["tor"]].
    var combos: [[String]]?
    var id: String { code }

    /// Whether one of its servers has all of these features.
    func hasServer(with features: Set<String>) -> Bool {
        guard let combos else { return features.isSubset(of: self.features) }
        return combos.contains { features.isSubset(of: $0) }
    }
}

struct Server: Decodable, Identifiable {
    var name: String
    var load: Int
    var entry: String?
    var features: [String]
    var id: String { name }
}

struct City: Decodable, Identifiable {
    var city: String
    var servers: [Server]
    var id: String { city }
}

/// Runs `vpn` with the given arguments, returning its exit status and output.
func runVPN(_ arguments: [String], started: (@Sendable (Process) -> Void)? = nil) async -> (Int32, String) {
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
            started?(process)
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
        ?? Bundle.main.url(forResource: name, withExtension: "icns")
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

    /// Proton's connected icon with its triangle filled with the country's flag. Not a template
    /// image, for the flag's colors, so the checkmark badge is drawn in the menu bar's text color.
    @MainActor static func flagged(_ code: String) -> NSImage {
        if let cached = flags[code] { return cached }
        let flagImage = trimmedFlag(code)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let scale = rect.width / 36
            let badge = CGRect(x: (25.6 - 10.8) * scale, y: (25.8 - 10.8) * scale, width: 21.6 * scale, height: 21.6 * scale)

            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            if let solid = solidTriangle { context.draw(solid, in: rect) }
            // The flag scaled to cover the triangle (in the icon's left 30x32), cropped at its sides
            // rather than stretched.
            let box = NSRect(x: 0, y: 0, width: 30 * scale, height: 32 * scale)
            let fill = max(box.width / flagImage.size.width, box.height / flagImage.size.height)
            let size = NSSize(width: flagImage.size.width * fill, height: flagImage.size.height * fill)
            flagImage.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceIn, fraction: 1)
            context.endTransparencyLayer()
            context.restoreGState()

            // The checkmark badge, in white or black like the menu bar's template icons.
            context.saveGState()
            context.addEllipse(in: badge)
            context.clip()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            resource("connected").draw(in: rect)
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor.white : NSColor.black).setFill()
            rect.fill(using: .sourceAtop)
            context.endTransparencyLayer()
            context.restoreGState()
            return true
        }
        flags[code] = image
        return image
    }

    /// Proton's triangle as one solid shape, without the badge or the line inside it, so the flag
    /// fills all of it: the convex hull of the triangle's pixels, with the gap around the badge
    /// (radius 12.1; the badge itself is 10.3) cut out again.
    static let solidTriangle: CGImage? = {
        let n = 144, scale = Double(n) / 36
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        resource("connected").draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()

        let center = CGPoint(x: 25.6 * scale, y: 25.8 * scale), gap = 12.1 * scale
        var points: [CGPoint] = []
        for y in 0..<n {
            for x in 0..<n where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(n - y) - 0.5)
                if hypot(point.x - center.x, point.y - center.y) > gap { points.append(point) }
            }
        }
        let hull = convexHull(points)
        guard hull.count > 2, let context = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                                       space: CGColorSpaceCreateDeviceRGB(),
                                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.addLines(between: hull)
        context.closePath()
        context.fillPath()
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: center.x - gap, y: center.y - gap, width: gap * 2, height: gap * 2))
        return context.makeImage()
    }()

    /// The smallest convex polygon around the points (Andrew's monotone chain).
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// The flag emoji, trimmed to the flag itself: the glyph has margins, and shading at the
    /// edges where it waves.
    static func trimmedFlag(_ code: String) -> NSImage {
        let text = NSAttributedString(string: flag(code), attributes: [.font: NSFont.systemFont(ofSize: 160)])
        let size = text.size()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        text.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()

        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let width = Double(maxX - minX), height = Double(maxY - minY)
        let crop = CGRect(x: Double(minX) + width * 0.06, y: Double(minY) + height * 0.1, width: width * 0.88, height: height * 0.8)
        guard width > 0, height > 0, let image = rep.cgImage?.cropping(to: crop) else { return NSImage() }
        return NSImage(cgImage: image, size: crop.size)
    }

    @MainActor private static var flags: [String: NSImage] = [:]

    /// Proton's icon with a (!) in its badge, for errors and dropped connections.
    static let error: NSImage = {
        let image = NSImage(size: size, flipped: false) { rect in
            resource("disconnected").draw(in: rect)
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let scale = rect.width / 36
            let center = CGPoint(x: 25.2 * scale, y: 25.6 * scale)
            let radius = 9.8 * scale
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.setBlendMode(.destinationOut)
            let width = 2.6 * scale
            context.addPath(CGPath(roundedRect: CGRect(x: center.x - width / 2, y: center.y - 1.2 * scale, width: width, height: 7.4 * scale),
                                   cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
            context.fillPath()
            context.fillEllipse(in: CGRect(x: center.x - width / 2, y: center.y - 5.4 * scale, width: width, height: width))
            return true
        }
        image.isTemplate = true
        return image
    }()

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
            if status.state == "Connected", let code = status.code {
                remember(code)
                UserDefaults.standard.set(code, forKey: "lastCountry")
            }
            if status.state != oldValue.state { Task { await loadPublicIP() } }
            // Done as soon as the tunnel is: Proton's CLI then spends seconds refreshing its server
            // list before it exits.
            if busy == "Disconnecting…" && status.state == "Disconnected" { busy = nil }
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
        // Proton rewrites settings.json in place, which only the file itself reports; the folder
        // reports it being created or removed (signing out removes it), to watch the new one.
        watch(settingsDirectory)
        watchSettingsFile()
        registerLoginItemOnce()
        // A newer release, checked on launch and then daily.
        Task { await checkForUpdates() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
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

    /// Refreshes whenever Proton's CLI, run from anywhere, saves or removes the connection or settings.
    private func watch(_ directory: String) {
        if !directory.hasSuffix(".json") {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            if directory == settingsDirectory { self?.watchSettingsFile() }
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
        let fd = open(settingsDirectory + "/settings.json", O_EVTONLY)
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
            let (code, output) = await runVPN(arguments) { process in
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
            message = code == 0 ? nil : (lines.first { $0.hasPrefix("Error") } ?? lines.last ?? "Failed")
        }
    }

    /// The features the country list is filtered by (p2p, tor, streaming), kept between launches.
    @Published var filters = Set(UserDefaults.standard.stringArray(forKey: "filters") ?? []) {
        didSet { UserDefaults.standard.set(Array(filters), forKey: "filters") }
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

    private var modeLabel: String {
        if secureCore { return " via Secure Core" }
        let labels = modeWords.map { $0 == "tor" ? "Tor" : "P2P" }
        return labels.isEmpty ? "" : " (\(labels.joined(separator: ", ")))"
    }

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
        let (status, output) = await runVPN(["servers"] + modeWords + [code, "--json"])
        if status == 0, let decoded = try? JSONDecoder().decode([City].self, from: Data(output.utf8)) {
            serverLists[key] = decoded
        }
    }

    /// Loads change all the time, so lists are fetched again the next time.
    func forgetServers() { serverLists = [:] }

    func connect(city: String, in country: Country) {
        guard busy == nil else { return }
        closePanel()
        connectingCode = country.code
        run("Connecting to \(city)\(modeLabel)…", ["city"] + modeWords + [city])
    }

    func connect(server: Server, in country: Country) {
        guard busy == nil else { return }
        closePanel()
        connectingCode = country.code
        run("Connecting to \(server.name)…", [server.name])
    }

    func connect(_ country: Country) {
        guard busy == nil else { return }
        closePanel()
        connectingCode = country.code
        run("Connecting to \(country.name)\(modeLabel)…", modeWords + [country.code])
    }
    func fastest() {
        closePanel()
        run("Connecting to the fastest server\(modeLabel)…", modeWords + ["fastest"])
    }

    func random() {
        closePanel()
        run("Connecting to a random server\(modeLabel)…", modeWords + ["random"])
    }

    /// The `vpn` command under way, for cancelling a connect.
    private var running: Process?
    private var cancelled: String?

    /// Disconnects, or cancels connecting by stopping that command first.
    func disconnect() {
        closePanel()
        if let busy, busy.hasPrefix("Connecting") || busy.hasPrefix("Reconnecting"), let running {
            cancelled = busy
            running.terminate()
            self.busy = nil
            connectingCode = nil
        }
        run("Disconnecting…", ["off"])
    }

    /// Closes the menu bar panel, once a connect or disconnect is under way. It's closed by clicking
    /// the menu bar item, as you would, since closing the window itself leaves the item highlighted
    /// and the next click only closes what's already gone.
    private func closePanel() {
        func statusButton(in view: NSView?) -> NSStatusBarButton? {
            guard let view else { return nil }
            if let button = view as? NSStatusBarButton { return button }
            return view.subviews.lazy.compactMap { statusButton(in: $0) }.first
        }
        let button = NSApp.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .lazy.compactMap { statusButton(in: $0.contentView) }
            .first
        if let button, NSApp.keyWindow != nil {
            button.performClick(nil)
        } else {
            NSApp.keyWindow?.close()
        }
    }

    /// Where Quick Connect goes: the last country, if it has servers for the current filters and
    /// Secure Core; otherwise the fastest server for them.
    var quickConnectCountry: Country? {
        guard account?.free != true, let code = UserDefaults.standard.string(forKey: "lastCountry") else { return nil }
        return available(countries).first { $0.code == code }
    }

    /// Turns Secure Core on, after a note about its speed (until that's turned off), or off.
    func toggleSecureCore() {
        guard !secureCore else { secureCore = false; return }
        if !UserDefaults.standard.bool(forKey: "skipSecureCoreNote") {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "A note about speed"
            alert.informativeText = "Secure Core routes your connection through a second server in Switzerland, Iceland or Sweden first. It's the most private option, but it can be slower. Turn it off if you need more speed."
            alert.addButton(withTitle: "Turn On Secure Core")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show again"
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "skipSecureCoreNote") }
            guard response == .alertFirstButtonReturn else { return }
        }
        secureCore = true
    }

    /// Quits, asking first while connected whether to leave the VPN on (the CLI and Alfred can still
    /// use it) or disconnect.
    func quit() {
        guard status.state != "Disconnected" else { NSApp.terminate(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit Proton VPN Menu Bar?"
        alert.informativeText = "You're connected to \(status.server ?? "Proton VPN"). It stays connected after quitting, unless you disconnect."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Disconnect and Quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            busy = "Disconnecting…"
            Task {
                _ = await runVPN(["off"])
                NSApp.terminate(nil)
            }
        default:
            break
        }
    }

    func quickConnect() {
        if let country = quickConnectCountry { connect(country) } else { fastest() }
    }
    func signOut() {
        guard busy == nil else { return }
        busy = "Signing out…"
        Task {
            _ = await runVPN(["signout"])
            busy = nil
            await loadAccount()
            await refresh()
        }
    }

    /// A newer release on GitHub, if there is one.
    @Published var update: (version: String, url: URL)?
    private var updateTimer: Timer?

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// Checks GitHub for a newer release; asked for from the menu, it also says when there isn't one.
    func checkForUpdates(manual: Bool = false) async {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/stevelacey/proton-vpn-menubar/releases/latest")!)
        request.timeoutInterval = 10
        struct Release: Decodable { let tag_name: String; let html_url: URL }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            if manual { alert("Couldn't check for updates", "GitHub didn't answer. Try again later.") }
            return
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            // No releases yet (a 404) means this is the latest.
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                if manual { alert("You're up to date", "Proton VPN Menu Bar \(Self.version) is the latest version.") }
                return
            }
            if manual { alert("Couldn't check for updates", "GitHub didn't answer. Try again later.") }
            return
        }
        let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        if latest.compare(Self.version, options: .numeric) == .orderedDescending {
            update = (latest, release.html_url)
            if manual { offerUpdate() }
        } else {
            update = nil
            if manual { alert("You're up to date", "Proton VPN Menu Bar \(Self.version) is the latest version.") }
        }
    }

    func offerUpdate() {
        guard let update else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Proton VPN Menu Bar \(update.version) is available"
        alert.informativeText = "You have \(Self.version). If you installed it with Homebrew, run `brew upgrade`; otherwise download the new version."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(update.url) }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// Connects again to the last country on launch, when disconnected.
    @Published var autoConnect = UserDefaults.standard.bool(forKey: "autoConnect") {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }

    @Published var showFlag = UserDefaults.standard.object(forKey: "showFlag") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFlag, forKey: "showFlag") }
    }

    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Opens at login by default, the first time the app runs.
    private func registerLoginItemOnce() {
        guard !UserDefaults.standard.bool(forKey: "loginItemRegistered") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemRegistered")
        setOpenAtLogin(true)
    }

    private func reconnectOnLaunch() {
        guard autoConnect, account != nil, status.state == "Disconnected" else { return }
        quickConnect()
    }

    /// Whether `vpn setup` still has to run, so connecting works without a password.
    @Published var needsSetup = false

    func checkSetup() async {
        let (code, _) = await runVPN(["setup", "--check"])
        needsSetup = code != 0
    }

    /// Runs `vpn setup` as root, with macOS asking for an administrator's password.
    func runSetup() {
        let command = "'\(vpnPath)' setup --user \(NSUserName())"
        let script = "do shell script \"\(command)\" with administrator privileges"
        busy = "Setting up…"
        Task {
            let (status, output) = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    var error: NSDictionary?
                    let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
                    continuation.resume(returning: (error == nil, result?.stringValue ?? (error?[NSAppleScript.errorMessage] as? String ?? "")))
                }
            }
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
        let (code, output) = await runVPN(["account", "--json"])
        // Keeps the last known account if the CLI fails, rather than showing the sign-in form.
        if code == 0 {
            account = try? JSONDecoder().decode(Account.self, from: Data(output.utf8))
        }
        accountLoaded = true
    }

    /// Signs in through `vpn signin --stdin`, which answers Proton's own prompts from what's typed here.
    func signIn(username: String, password: String) {
        guard signInProcess == nil else { return }
        signIn = .working
        signInError = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: vpnPath)
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
            signInError = "Couldn't run \(vpnPath)"
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
        // Port forwarding only works on P2P servers, so it's one more feature to have.
        let required = settings.portForwarding ? filters.union(["p2p"]) : filters
        if !required.isEmpty { return list.filter { $0.hasServer(with: required) } }
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
        if status.state == "Dropped" || (message != nil && status.state != "Connected") { return MenuBarIcon.error }
        if showFlag, status.state == "Connected", let code = status.code { return MenuBarIcon.flagged(code) }
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
    let expanded: Bool
    let toggleExpanded: () -> Void
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
                ExpandButton(expanded: expanded, action: toggleExpanded)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A chevron that shows a country's cities and servers.
struct ExpandButton: View {
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide servers" : "Show servers")
    }
}

/// A city in an expanded country; connects to its fastest server.
struct CityRow: View {
    let city: City
    let expanded: Bool
    let toggleExpanded: () -> Void
    let action: () -> Void

    var body: some View {
        HoverButton(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                Text(city.city)
                Spacer()
                Text("\(city.servers.count)").font(.caption).foregroundStyle(.secondary)
                ExpandButton(expanded: expanded, action: toggleExpanded)
            }
        }
        .padding(.leading, 16)
    }
}

/// A server, with its load like Proton's app; connects to it.
struct ServerRow: View {
    let server: Server
    let country: String
    let current: Bool
    let action: () -> Void

    var loadColor: Color { server.load < 75 ? .green : server.load < 90 ? .yellow : .red }

    var body: some View {
        HoverButton(action: action) {
            HStack(spacing: 8) {
                Text(server.name).fontWeight(current ? .semibold : .regular).monospacedDigit()
                if let entry = server.entry, entry != country {
                    Text("via \(flag(entry))").font(.caption).foregroundStyle(.secondary)
                }
                if current {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                Spacer()
                FeatureIcons(features: server.features)
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: 28, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(loadColor).frame(width: 28 * CGFloat(min(server.load, 100)) / 100, height: 4)
                    }
                Text("\(server.load)%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(.leading, 16)
    }
}

/// A feature filter beside the search field.
struct FilterButton: View {
    let feature: String
    let title: String
    let image: Image
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .padding(4)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Showing \(title) countries only" : "Show \(title) countries only")
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

/// The country connected to (or connecting or dropped), tinted by state; clicking it disconnects (or
/// cancels).
struct ActiveCountryRow: View {
    let country: Country
    let state: String
    let expanded: Bool
    let toggleExpanded: () -> Void
    let pinned: Bool
    let togglePin: () -> Void
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
        Button(action: disconnect) {
            HStack(spacing: 8) {
                Text(flag(country.code))
                Text(country.name).fontWeight(.semibold)
                Spacer()
                FeatureIcons(features: country.features)
                PinButton(pinned: pinned, visible: hovering, action: togglePin)
                ExpandButton(expanded: expanded, action: toggleExpanded)
            }
            // The same as the other rows, so the list doesn't change height as you connect.
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(state == "Connecting" ? "Cancel" : "Disconnect")
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

/// macOS's standard About window, with credits linking to the project and its siblings.
@MainActor func showAbout() {
    let link = { (text: String, url: String) in
        NSAttributedString(string: text, attributes: [.link: URL(string: url)!])
    }
    let credits = NSMutableAttributedString()
    let lines: [[NSAttributedString]] = [
        [NSAttributedString(string: "A small menu bar app for Proton VPN, compatible with the ")],
        [link("Proton VPN CLI", "https://github.com/stevelacey/proton-vpn-cli-macos"), NSAttributedString(string: " (forked for macOS) and "),
         link("Alfred workflow", "https://github.com/stevelacey/alfred-proton-vpn"), NSAttributedString(string: ".\n\n")],
        [link("Fork on GitHub", "https://github.com/stevelacey/proton-vpn-menubar"), NSAttributedString(string: "  ·  "),
         // UTM tags, so steve.ly's analytics can tell visits from the app apart.
         link("Made with ♥ by Steve", "https://steve.ly/?utm_source=proton-vpn-menubar&utm_medium=app")],
    ]
    for part in lines.flatMap({ $0 }) { credits.append(part) }
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    credits.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: style,
                           .foregroundColor: NSColor.secondaryLabelColor],
                          range: NSRange(location: 0, length: credits.length))
    NSApp.activate(ignoringOtherApps: true)
    // No build number: it would only repeat the version.
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .version: ""])
}

extension View {
    /// The header's lines have fixed heights, so the panel doesn't change height between states.
    func titleLine() -> some View { frame(height: 24, alignment: .leading) }
    func infoLine() -> some View { frame(height: 20, alignment: .leading) }
}

/// Shown when the `vpn` command isn't installed.
struct InstallCLI: View {
    let command = "brew install stevelacey/tap/proton-vpn-cli"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Install the CLI").font(.title3.weight(.semibold))
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Quit")
            }
            Text("This app runs on the Proton VPN CLI, forked for macOS. Install it with Homebrew:")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            Text("Then reopen this app.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// Signing in, shown in place of everything else while signed out.
struct SignInForm: View {
    @ObservedObject var vpn: VPN
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Quit")
            }
            .padding(.bottom, -14)
            VStack(spacing: 6) {
                Image(nsImage: resource("AppIcon", template: false))
                    .resizable()
                    .frame(width: 56, height: 56)
                Text(isCode ? "Two-factor authentication" : "Sign in to Proton VPN")
                    .font(.title2.weight(.semibold))
                if isCode {
                    Text("Enter the 6-digit code from your authenticator app, or a recovery code.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)

            Text("Unofficial app, not affiliated with Proton AG")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, -8)

            if isCode {
                field("Code") {
                    TextField("123456", text: $code).onSubmit(submitCode)
                }
                if case .code(invalid: true) = vpn.signIn {
                    errorText("That code didn't work. Try again.")
                }
                primaryButton("Continue", disabled: code.isEmpty, action: submitCode)
                Button("Cancel") { vpn.cancelSignIn() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                field("Email or username") {
                    TextField("", text: $username).textContentType(.username)
                }
                field("Password", link: ("Forgot password?", "https://account.proton.me/reset-password")) {
                    SecureField("", text: $password).textContentType(.password).onSubmit(submit)
                }
                if let error = vpn.signInError {
                    errorText(error)
                }
                primaryButton(vpn.signIn == .working ? "Signing in…" : "Sign in",
                              disabled: username.isEmpty || password.isEmpty || vpn.signIn == .working,
                              action: submit)
            }

            Divider()
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
                Text("Signs in with the Proton VPN CLI (forked for macOS), straight to Proton. Your password isn't stored; the session is kept in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("Create a free account", destination: URL(string: "https://account.protonvpn.com/signup")!)
                .font(.caption)
        }
        .padding(20)
        .frame(width: 320)
    }

    var isCode: Bool {
        if case .code = vpn.signIn { return true }
        return false
    }

    func field(_ label: String, link: (String, String)? = nil, @ViewBuilder input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let link {
                    Link(link.0, destination: URL(string: link.1)!).font(.caption)
                }
            }
            input()
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        }
    }

    func errorText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(notConnected)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    func primaryButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if vpn.signIn == .working { ProgressView().controlSize(.small).tint(.white) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(disabled ? 0.45 : 1)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }

    func submit() {
        guard !username.isEmpty, !password.isEmpty else { return }
        vpn.signIn(username: username, password: password)
        password = ""
    }

    func submitCode() {
        guard !code.isEmpty else { return }
        vpn.submit(code: code)
        code = ""
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

/// Quick Connect while disconnected (to the last country, with the current filters); Cancel while
/// connecting and Disconnect once connected, in its place.
struct QuickConnectButton: View {
    @ObservedObject var vpn: VPN

    var body: some View {
        switch vpn.activeState {
        case "Disconnected":
            ActionButton(title: "Quick Connect", symbol: "bolt.horizontal.fill") { vpn.quickConnect() }
                .disabled(vpn.busy != nil)
        case "Connecting":
            ActionButton(title: "Cancel", symbol: "xmark") { vpn.disconnect() }
        default:
            ActionButton(title: "Disconnect", symbol: "bolt.slash.fill") { vpn.disconnect() }
                .disabled(vpn.busy != nil)
        }
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
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Panel: View {
    @ObservedObject var vpn: VPN
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var expanded: String?
    @State private var expandedCity: String?
    @State private var serverLimit = serverPage
    @State private var listHeight: CGFloat = 0

    var body: some View {
        if !cliInstalled {
            InstallCLI()
        } else if !vpn.accountLoaded {
            ProgressView().controlSize(.small).frame(width: 320, height: 80)
        } else if vpn.account == nil {
            SignInForm(vpn: vpn)
        } else {
            panel
        }
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

            QuickConnectButton(vpn: vpn)

            if vpn.account?.free == true {
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
        .onDisappear {
            query = ""
            expanded = nil
            vpn.forgetServers()
        }
    }

    /// Everything a paid plan can choose: quick connects, features and countries.
    @ViewBuilder var paidControls: some View {
            HStack(spacing: 8) {
                ActionButton(title: "Fastest", symbol: "bolt.fill") { vpn.fastest() }
                ActionButton(title: "Random", symbol: "shuffle") { vpn.random() }
            }

            HStack(spacing: 6) {
                Toggle(title: "Secure Core", image: Image(nsImage: resource("ic-lock")), on: vpn.secureCore) {
                    vpn.toggleSecureCore()
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

    @ViewBuilder var countries: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(vpn.secureCore ? "Search Secure Core countries" : "Search countries", text: $query)
                    .focused($searchFocused)
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
                HStack(spacing: 0) {
                    ForEach(filters, id: \.feature) { filter in
                        FilterButton(feature: filter.feature, title: filter.title, image: filter.image,
                                     selected: vpn.filters.contains(filter.feature)) {
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
                    ForEach(list) { c in
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
            CountryRow(country: c, pinned: vpn.pinnedCodes.contains(c.code), togglePin: { vpn.togglePin(c.code) },
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
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
                .padding(.vertical, 4)
        }
    }

    /// Recent countries, all countries with the filtered features, or search results while typing.
    var listed: [Country] {
        if !query.isEmpty { return Array(vpn.search(query).prefix(10)) }
        if !vpn.filters.isEmpty {
            // Pinned countries that match stay on top, then the rest from A to Z.
            let matching = vpn.available(vpn.countries)
            let pinned = vpn.pinnedCodes.compactMap { code in matching.first { $0.code == code } }
            return pinned + matching.filter { !vpn.pinnedCodes.contains($0.code) }.sorted { $0.name < $1.name }
        }
        return vpn.available(vpn.recents)
    }

    var filters: [(feature: String, title: String, image: Image)] {
        [
            ("p2p", "P2P", Image(systemName: "arrow.left.arrow.right")),
            ("tor", "Tor", Image(nsImage: resource("ic-brand-tor"))),
            ("streaming", "streaming", Image(systemName: "play")),
        ]
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
            // Always two lines (a title, then the IP or server), so the panel keeps its height.
            if let busy = vpn.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                }
                .padding(.trailing, 50)
                .titleLine()
                ipLabel(vpn.status.state == "Connected" ? vpn.status.ip : vpn.publicIP).infoLine()
            } else {
                switch vpn.status.state {
                case "Connected":
                    HStack(spacing: 6) {
                        Text(flag(vpn.status.code ?? ""))
                        Text(vpn.status.country ?? "").fontWeight(.semibold)
                        Text(vpn.status.server ?? "").foregroundStyle(.secondary)
                    }
                    .font(.title3)
                    .padding(.trailing, 50)
                    .titleLine()
                    .help(vpn.status.city ?? "")
                    HStack(spacing: 4) {
                        ipLabel(vpn.status.ip)
                        Spacer()
                        dnsMenu
                    }
                    .infoLine()
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
                        Text("Connecting…").font(.title3.weight(.semibold))
                    }
                    .padding(.trailing, 50)
                    .titleLine()
                    Text(vpn.status.server ?? "").font(.callout).foregroundStyle(.secondary).infoLine()
                case "Dropped":
                    Text("Connection Dropped").font(.title3.weight(.semibold)).foregroundStyle(.orange).titleLine()
                    Text("\(vpn.status.server ?? "The server") stopped responding").font(.callout).foregroundStyle(.secondary).infoLine()
                default:
                    Text("Not Connected").font(.title3.weight(.semibold)).foregroundStyle(notConnected).titleLine()
                    // DNS only applies to the tunnel, so there's nothing to pick while disconnected.
                    ipLabel(vpn.publicIP).infoLine()
                }
            }
            if let message = vpn.message {
                Text(message).foregroundStyle(.red).font(.caption).lineLimit(3)
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
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusable(false)
                .help("Settings")
                Button { vpn.quit() } label: { Image(systemName: "power") }
                    .buttonStyle(.plain)
                    .focusable(false)
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
