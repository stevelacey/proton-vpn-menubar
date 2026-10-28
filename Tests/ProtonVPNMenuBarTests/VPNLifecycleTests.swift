import AppKit
import Foundation
import Testing
@testable import ProtonVPNMenuBar

@MainActor @Suite struct VPNLifecycleTests {
    func release(_ tag: String) -> (Data, Int) {
        (Data(#"{"tag_name": "\#(tag)", "html_url": "https://github.com/stevelacey/proton-vpn-menubar/releases/tag/\#(tag)"}"#.utf8), 200)
    }

    @Test func checksForUpdates() async {
        let harness = Harness(version: "1.0.0")
        let vpn = harness.vpn
        var alerts: [String] = []
        var offered = 0
        vpn.onAlert = { title, _ in alerts.append(title) }
        vpn.onUpdateAvailable = { offered += 1 }

        await vpn.checkForUpdates()
        await vpn.checkForUpdates(manual: true)
        harness.network.responses = [(Data(), 404), (Data(), 404), (Data(), 500), (Data(), 500)]
        await vpn.checkForUpdates()
        await vpn.checkForUpdates(manual: true)
        await vpn.checkForUpdates()
        await vpn.checkForUpdates(manual: true)
        harness.network.responses = [release("v1.1.0"), release("1.1.0"), release("1.0.0"), release("0.9.0")]
        await vpn.checkForUpdates()
        #expect(vpn.update?.version == "1.1.0" && offered == 0)
        await vpn.checkForUpdates(manual: true)
        #expect(offered == 1)
        await vpn.checkForUpdates()
        #expect(vpn.update == nil)
        await vpn.checkForUpdates(manual: true)
        #expect(alerts == ["Couldn't check for updates", "You're up to date", "Couldn't check for updates", "You're up to date"])
        #expect(harness.network.requests[0].url?.absoluteString
            == "https://api.github.com/repos/stevelacey/proton-vpn-menubar/releases/latest")
        // The app's own alerts by default.
        let plain = Harness().vpn
        plain.onAlert("title", "text")
        plain.onUpdateAvailable()
    }

    @Test func startLoadsEverythingAndReconnects() async {
        let harness = Harness { $0.set(true, forKey: "autoConnect"); $0.set("CH", forKey: "lastCountry") }
        harness.fake.respondJSON("account --json", ["username": "me", "plan": "Plus", "tier": 2])
        harness.fake.respondJSON("list --json", [countryJSON(switzerland)])
        harness.fake.respond("setup --check", "", status: 1)
        let vpn = harness.vpn
        vpn.start()
        await eventually { harness.fake.calls.contains("CH") }
        #expect(vpn.account?.username == "me" && vpn.needsSetup && vpn.openAtLogin)
        #expect(harness.defaults.bool(forKey: "loginItemRegistered"))
        #expect(harness.fake.calls.starts(with: ["account --json", "setup --check", "status --json", "settings --json", "list --json"]))
    }

    @Test func startDoesntReconnectWhenItShouldnt() async {
        let harness = Harness { $0.set(true, forKey: "loginItemRegistered") }
        harness.fake.respondJSON("account --json", ["username": "me", "plan": "Plus", "tier": 2])
        let vpn = harness.vpn
        vpn.start()
        await eventually { harness.fake.calls.count >= 5 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!vpn.openAtLogin)
        #expect(!harness.fake.calls.contains("fastest"))
    }

    @Test func pollsAndChecksForUpdatesOnATimer() async {
        let harness = Harness()
        let vpn = harness.vpn
        vpn.pollInterval = 0.1
        vpn.updateInterval = 0.1
        vpn.start()
        await eventually { harness.fake.calls.filter { $0 == "status --json" }.count >= 3 && harness.network.requests.count >= 3 }
    }

    @Test func refreshesWhenTheConnectionOrSettingsChange() async throws {
        let harness = Harness()
        let vpn = harness.vpn
        let settings = URL(fileURLWithPath: harness.fake.settings).appendingPathComponent("settings.json")
        let statusCalls = { harness.fake.calls.filter { $0 == "status --json" }.count }
        vpn.start()
        await eventually { statusCalls() >= 1 }

        try "{}".write(toFile: harness.fake.connection + "/connection_persistence.json", atomically: false, encoding: .utf8)
        await eventually { statusCalls() >= 2 }
        // The settings file appearing, changing, and going.
        try "{}".write(to: settings, atomically: false, encoding: .utf8)
        await eventually { statusCalls() >= 3 }
        let before = statusCalls()
        try "{\"x\": 1}".write(to: settings, atomically: false, encoding: .utf8)
        await eventually { statusCalls() > before }
        let beforeRemoval = statusCalls()
        try FileManager.default.removeItem(at: settings)
        await eventually { statusCalls() > beforeRemoval }
    }

    @Test func watchingAFolderThatCantExist() {
        let harness = Harness()
        FileManager.default.createFile(atPath: harness.fake.directory.appendingPathComponent("file").path, contents: nil)
        var environment = harness.vpn.environment
        environment.connectionDirectory = harness.fake.directory.appendingPathComponent("file/connection").path
        environment.settingsDirectory = environment.connectionDirectory
        VPN(environment: environment).start()
    }

    @Test func refreshesWhenTheForwardedPortChanges() async throws {
        let harness = Harness()
        let vpn = harness.vpn
        let statusCalls = { harness.fake.calls.filter { $0 == "status --json" }.count }
        vpn.start()
        await eventually { statusCalls() >= 1 }
        let before = statusCalls()
        try "4242".write(toFile: harness.fake.forwardedPort + "/forwarded_port", atomically: false, encoding: .utf8)
        await eventually { statusCalls() > before }
        // It doesn't run a forwarder of its own: the CLI does.
        #expect(!harness.fake.calls.contains("forward"))
    }

    @Test func signsInWithTwoFactorCodes() async {
        let harness = Harness()
        harness.fake.respondJSON("account --json", ["username": "me", "plan": "Plus", "tier": 2])
        let vpn = harness.vpn
        vpn.signIn(username: "me", password: "secret")
        #expect(vpn.signIn == .working)
        vpn.signIn(username: "again", password: "x")
        await eventually { vpn.signIn == .code(invalid: false) }
        vpn.submit(code: "000000")
        // Still on the code, checking it, rather than back to the form.
        #expect(vpn.signIn == .checkingCode)
        await eventually { vpn.signIn == .code(invalid: true) }
        vpn.submit(code: "123456")
        await eventually { vpn.account?.username == "me" }
        #expect(vpn.signIn == .form && vpn.signInError == nil)
    }

    @Test func signInErrors() async {
        let harness = Harness()
        let vpn = harness.vpn
        vpn.signIn(username: "me", password: "wrong")
        await eventually { vpn.signInError == "Invalid credentials" }
        #expect(vpn.signIn == .form)
    }

    @Test func cancellingSignIn() async {
        let harness = Harness()
        let vpn = harness.vpn
        vpn.signIn(username: "me", password: "secret")
        await eventually { vpn.signIn == .code(invalid: false) }
        vpn.cancelSignIn()
        #expect(vpn.signIn == .form)
        // Once it's gone, signing in works again.
        try? await Task.sleep(for: .milliseconds(300))
        vpn.signIn(username: "me", password: "secret")
        await eventually { vpn.signIn == .code(invalid: false) }
        vpn.cancelSignIn()
    }

    @Test func signInEndingByItselfShowsTheForm() async {
        let harness = Harness()
        let vpn = harness.vpn
        vpn.signIn(username: "me", password: "secret")
        await eventually { vpn.signIn == .code(invalid: false) }
        vpn.submit(code: "")
        // A reply that isn't one it knows, then the process ends.
        await eventually { vpn.signIn == .form }
    }

    @Test func signInWithoutTheCLI() {
        let harness = Harness()
        var environment = harness.vpn.environment
        environment.vpnPath = "/nowhere/vpn"
        let vpn = VPN(environment: environment)
        vpn.signIn(username: "me", password: "secret")
        #expect(vpn.signIn == .form && vpn.signInError == "Couldn't run /nowhere/vpn")
    }
}
