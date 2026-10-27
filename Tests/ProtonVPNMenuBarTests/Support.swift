import Foundation
import Testing
@testable import ProtonVPNMenuBar

/// A fake `vpn` command in a temporary folder: it records each call and answers with the output and
/// exit status saved for those arguments, so the app's real process handling runs.
final class FakeVPN: @unchecked Sendable {
    let directory: URL
    var path: String { directory.appendingPathComponent("vpn").path }
    var connection: String { directory.appendingPathComponent("connection").path }
    var settings: String { directory.appendingPathComponent("settings").path }
    var forwardedPort: String { directory.appendingPathComponent("forwarded").path }

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vpn-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: Self.script)
    }

    /// The script, one file for every fake: macOS checks each new executable the first time it runs,
    /// one at a time, which with a file per test held them up for seconds when they ran together.
    private static let script: String = {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("proton-vpn-menubar-fake-vpn").path
        let script = #"""
        #!/bin/bash
        dir="$(dirname "$0")"
        echo "$*" >> "$dir/calls"
        key=$(echo "$*" | tr ' /#' '___')
        if [ "$1" = signin ]; then
            read -r username; read -r password
            if [ "$password" = wrong ]; then echo "error Invalid credentials"; exit 1; fi
            echo "2fa"
            read -r code
            if [ "$code" = 000000 ]; then echo "2fa invalid"; read -r code; fi
            echo "ok $username"
            exit 0
        fi
        [ -f "$dir/$key.sleep" ] && sleep "$(cat "$dir/$key.sleep")"
        [ -f "$dir/$key.out" ] && cat "$dir/$key.out"
        [ -f "$dir/$key.code" ] && exit "$(cat "$dir/$key.code")"
        exit 0
        """#
        // Kept from one run to the next, unless the script changes.
        if FileManager.default.contents(atPath: path) != Data(script.utf8) {
            try? FileManager.default.removeItem(atPath: path)
            FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        }
        return path
    }()

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func file(_ arguments: String, _ suffix: String) -> URL {
        let key = arguments.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "#", with: "_")
        return directory.appendingPathComponent("\(key).\(suffix)")
    }

    /// Answers `vpn <arguments>` with this output and status, after a pause if given.
    func respond(_ arguments: String, _ output: String = "", status: Int32 = 0, after seconds: Double? = nil) {
        try! output.write(to: file(arguments, "out"), atomically: true, encoding: .utf8)
        try! String(status).write(to: file(arguments, "code"), atomically: true, encoding: .utf8)
        if let seconds { try! String(seconds).write(to: file(arguments, "sleep"), atomically: true, encoding: .utf8) }
    }

    func respondJSON(_ arguments: String, _ value: Any) {
        respond(arguments, String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }

    var calls: [String] {
        ((try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

final class FakeLoginItem: LoginItem, @unchecked Sendable {
    var enabled = false
    var failure: Error?

    func register() throws {
        if let failure { throw failure }
        enabled = true
    }

    func unregister() throws {
        if let failure { throw failure }
        enabled = false
    }
}

struct Failure: LocalizedError {
    var errorDescription: String? { "it failed" }
}

/// Answers each request with the next of these responses, or fails when there are none left.
final class FakeNetwork: @unchecked Sendable {
    var responses: [(Data, Int)] = []
    var requests: [URLRequest] = []

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw Failure() }
        let (data, status) = responses.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
struct Harness {
    let vpn: VPN
    let fake: FakeVPN
    let loginItem: FakeLoginItem
    let network: FakeNetwork
    let defaults: UserDefaults
    let admin: AdminPrompt

    final class AdminPrompt: @unchecked Sendable {
        var commands: [String] = []
        var result = (ok: true, output: "")
    }

    init(version: String = "1.0.0", configure: (UserDefaults) -> Void = { _ in }) {
        fake = FakeVPN()
        loginItem = FakeLoginItem()
        network = FakeNetwork()
        defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        configure(defaults)
        let admin = AdminPrompt()
        self.admin = admin
        let network = network
        vpn = VPN(environment: AppEnvironment(
            vpnPath: fake.path, connectionDirectory: fake.connection, settingsDirectory: fake.settings,
            forwardedPortDirectory: fake.forwardedPort,
            defaults: defaults, version: version, fetch: { try await network.fetch($0) }, loginItem: loginItem,
            runAsAdministrator: { command in
                admin.commands.append(command)
                return admin.result
            }))
    }
}

/// Waits for a condition the app reaches asynchronously, e.g. once a command finishes.
@MainActor
func eventually(_ condition: () -> Bool, timeout: Double = 5, sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), sourceLocation: sourceLocation)
}

let switzerland = Country(code: "CH", name: "Switzerland", servers: 3, aliases: ["swiss"],
                          features: ["p2p", "securecore", "streaming"], combos: [["p2p", "streaming"], ["securecore"]])
let unitedStates = Country(code: "US", name: "United States", servers: 2, aliases: ["usa", "america"],
                           features: ["p2p", "tor"], combos: [["p2p"], ["tor"]])
let unitedKingdom = Country(code: "UK", name: "United Kingdom", servers: 1, aliases: ["gb", "britain"],
                            features: ["streaming"], combos: nil)
let japan = Country(code: "JP", name: "Japan", servers: 1, aliases: [], features: [], combos: [])

func countryJSON(_ c: Country) -> [String: Any] {
    var json: [String: Any] = ["code": c.code, "name": c.name, "servers": c.servers, "aliases": c.aliases, "features": c.features]
    if let combos = c.combos { json["combos"] = combos }
    return json
}

/// The repo's Resources, standing in for the app bundle's.
let repoResources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources")
