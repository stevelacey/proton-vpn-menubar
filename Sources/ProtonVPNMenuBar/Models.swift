// Proton VPN in the menu bar: status, quick actions and a country search, all through the `protonvpn` CLI.
import AppKit

/// What the app reads, runs and asks the system for; tests swap in their own.
struct AppEnvironment {
    /// The `protonvpn` command from proton-vpn-cli-macos.
    var vpnPath: String
    /// Where Proton's CLI keeps the connection, and its settings.
    var connectionDirectory: String
    var settingsDirectory: String
    /// Where `protonvpn forward`, which the CLI runs in the background, keeps the forwarded port.
    var forwardedPortDirectory: String
    var defaults: UserDefaults
    var version: String
    var fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    var loginItem: LoginItem
    /// Runs a command as root, with macOS asking for an administrator's password.
    var runAsAdministrator: @Sendable (String) async -> (ok: Bool, output: String)

    var cliInstalled: Bool { FileManager.default.isExecutableFile(atPath: vpnPath) }

    /// The `protonvpn` command wherever Homebrew, uv or pipx put it.
    static func findVPN(home: String, configured: String?, isExecutable: (String) -> Bool) -> String {
        let candidates = [configured, "/opt/homebrew/bin/protonvpn", "/usr/local/bin/protonvpn", "\(home)/.local/bin/protonvpn"].compactMap { $0 }
        return candidates.first(where: isExecutable) ?? "/opt/homebrew/bin/protonvpn"
    }
}

/// Opening at login, which macOS's Service Management does for the app.
protocol LoginItem {
    var enabled: Bool { get }
    func register() throws
    func unregister() throws
}

/// DNS choices, as `protonvpn dns` names and labels.
let dnsChoices: [(String, String)] = [
    ("proton", "Proton"), ("cloudflare", "Cloudflare"), ("google", "Google"),
    ("opendns", "OpenDNS"), ("quad9", "Quad9"),
]

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
    var interface: String?
    var load: Int?
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

/// Runs `protonvpn` with the given arguments, returning its exit status and output.
func runVPN(_ vpnPath: String, _ arguments: [String], started: (@Sendable (Process) -> Void)? = nil) async -> (Int32, String) {
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

/// Where the images are: the app's Resources, or the repo's for tests.
nonisolated(unsafe) var resourceDirectory = Bundle.main.resourceURL

/// An image from the app's Resources, taken from Proton's app.
func resource(_ name: String, template: Bool = true) -> NSImage {
    let url = ["pdf", "png", "icns"].lazy
        .map { resourceDirectory?.appendingPathComponent("\(name).\($0)") }
        .first { $0.map { FileManager.default.fileExists(atPath: $0.path) } ?? false } ?? nil
    let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    image.isTemplate = template
    return image
}

/// NetShield's levels, as Proton's apps offer them.
struct NetShieldLevel {
    let level: Int
    let title: String
    let value: String

    static let all = [
        NetShieldLevel(level: 0, title: "Don't Block", value: "off"),
        NetShieldLevel(level: 1, title: "Block Malware Only", value: "malware-only"),
        NetShieldLevel(level: 2, title: "Block Malware, Ads and Trackers", value: "malware-ads-trackers"),
        NetShieldLevel(level: 3, title: "Block Malware, Ads, Trackers and Adult Content", value: "malware-ads-trackers-adult"),
    ]
}

/// What each server feature is for, in Proton's words, for tooltips.
let featureTips = [
    "p2p": "P2P: best for BitTorrent and file sharing",
    "tor": "Tor over VPN: slower but more private",
    "streaming": "Streaming: Netflix, Disney+ and more from anywhere",
    "smartrouting": "Smart Routing: a virtual location, served from a nearby country",
]


/// Bytes per second as KB/s, MB/s or GB/s.
func rate(_ bytesPerSecond: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
}
