import AppKit
import Foundation
import Testing
@testable import ProtonVPNMenuBar

@MainActor @Suite struct VPNCommandTests {
    @Test func refreshLoadsStatusSettingsAndCountries() async {
        let harness = Harness()
        harness.fake.respondJSON("status --json", ["state": "Connected", "server": "CH#1", "code": "CH", "load": 40])
        harness.fake.respondJSON("settings --json", ["netshield": 2, "kill_switch": 1, "port_forwarding": false, "dns": "google"])
        harness.fake.respondJSON("list --json", [countryJSON(switzerland)])
        let vpn = harness.vpn
        await vpn.refresh()
        #expect(vpn.status.server == "CH#1" && vpn.status.load == 40)
        #expect(vpn.settings == Settings(netshield: 2, killSwitch: 1, portForwarding: false, dns: "google"))
        #expect(vpn.countries == [switzerland])
        // Countries are only loaded once.
        await vpn.refresh()
        #expect(harness.fake.calls.filter { $0 == "list --json" }.count == 1)
    }

    @Test func refreshLoadsOutdatedTools() async {
        let harness = Harness()
        harness.fake.respondJSON("status --json", ["state": "Disconnected", "outdated_tools": ["bash"]])
        harness.fake.respond("settings --json", "", status: 1)
        harness.fake.respond("list --json", "", status: 1)
        let vpn = harness.vpn
        await vpn.refresh()
        #expect(vpn.status.outdatedTools == ["bash"])
    }

    @Test func refreshWaitsForWhatsInProgressUnlessForced() async {
        let harness = Harness()
        harness.fake.respond("status --json", "not json")
        harness.fake.respond("settings --json", "", status: 1)
        harness.fake.respond("list --json", "", status: 1)
        let vpn = harness.vpn
        vpn.busy = "Connecting…"
        await vpn.refresh()
        #expect(harness.fake.calls.isEmpty)
        await vpn.refresh(force: true)
        #expect(harness.fake.calls == ["status --json", "settings --json", "list --json"])
        #expect(vpn.status.state == "Disconnected" && vpn.countries.isEmpty)
        vpn.busy = nil
    }

    @Test func publicIPWhileDisconnected() async {
        let harness = Harness()
        let vpn = harness.vpn
        await vpn.loadPublicIP()
        #expect(vpn.publicIP == nil)
        harness.network.responses = [(Data("fl=1\nip=203.0.113.4\nloc=BR\nbroken\n".utf8), 200)]
        await vpn.loadPublicIP()
        #expect(vpn.publicIP == "203.0.113.4")
        #expect(harness.network.requests.last?.url?.absoluteString == "https://1.1.1.1/cdn-cgi/trace")
        harness.network.responses = [(Data("ip=198.51.100.1\n".utf8), 200)]
        vpn.status = Status(state: "Connected", server: "CH#1")
        await vpn.loadPublicIP()
        #expect(vpn.publicIP == "203.0.113.4")
    }

    @Test func keepsTheOldIPIfTheConnectionChangesMeanwhile() async {
        let harness = Harness()
        let vpn = harness.vpn
        harness.network.responses = [(Data("ip=198.51.100.1\n".utf8), 200)]
        let lookup = Task { await vpn.loadPublicIP() }
        vpn.status = Status(state: "Connecting", server: "CH#1")
        await lookup.value
        #expect(vpn.publicIP == nil)
    }

    @Test func samplesDNSAndSpeeds() async {
        let vpn = Harness().vpn
        vpn.systemDNS = "x"
        vpn.sample()
        #expect(vpn.systemDNS != "x" && vpn.speeds == nil)
        vpn.status = Status(state: "Connected", server: "CH#1", interface: "lo0")
        vpn.sample()
        #expect(vpn.speeds == nil)
        try? await Task.sleep(for: .milliseconds(50))
        vpn.sample()
        #expect(vpn.speeds != nil)
        vpn.status = Status(state: "Connected", server: "CH#1", interface: "nope0")
        vpn.sample()
        #expect(vpn.speeds == nil)
    }

    @Test func runReportsFailuresWithoutProtonsErrorPrefix() async {
        let harness = Harness()
        harness.fake.respond("CH", "Connecting…\nError: No servers found\nmore\n", status: 1)
        harness.fake.respond("JP", "first\nlast\n", status: 1)
        harness.fake.respond("US", "", status: 1)
        let vpn = harness.vpn
        vpn.connect(switzerland)
        #expect(vpn.busy == "Connecting to Switzerland…" && vpn.connectingCode == "CH")
        // One thing at a time.
        vpn.connect(japan)
        vpn.connect(city: "Tokyo", in: japan)
        vpn.connect(server: Server(name: "JP#1", load: 1, entry: nil, features: []), in: japan)
        vpn.run("Other", ["other"])
        await eventually { vpn.message == "No servers found" }
        #expect(vpn.connectingCode == nil)
        vpn.connect(japan)
        await eventually { vpn.message == "last" }
        vpn.connect(unitedStates)
        await eventually { vpn.message == "Failed" }
        #expect(!harness.fake.calls.contains("other"))
    }

    @Test func aFailureIsOldNewsOnceConnectedElsewhere() async {
        let harness = Harness()
        harness.fake.respond("CH", "Error: timed out", status: 1)
        harness.fake.respondJSON("status --json", ["state": "Connected", "server": "JP#1", "code": "JP"])
        let vpn = harness.vpn
        vpn.connect(switzerland)
        await eventually { vpn.busy == nil && vpn.status.state == "Connected" }
        #expect(vpn.message == nil)
    }

    @Test func disconnectCancelsConnecting() async {
        let harness = Harness()
        harness.fake.respond("CH", "", after: 5)
        let vpn = harness.vpn
        vpn.connect(switzerland)
        // Before the command has started, there's nothing to cancel.
        await eventually { harness.fake.calls.contains("CH") }
        try? await Task.sleep(for: .milliseconds(200))
        vpn.disconnect()
        #expect(vpn.busy == "Disconnecting…" && vpn.connectingCode == nil)
        await eventually { vpn.busy == nil }
        #expect(harness.fake.calls.contains("off") && vpn.message == nil)
    }

    @Test func disconnectWhileConnected() async {
        let harness = Harness()
        let vpn = harness.vpn
        vpn.disconnect()
        await eventually { vpn.busy == nil }
        #expect(harness.fake.calls.first == "off")
    }

    @Test func serverListsLoadOncePerModeAndFilter() async {
        let harness = Harness()
        let cities: [[String: Any]] = [
            ["city": "Zurich", "servers": [["name": "CH#1", "load": 30, "features": ["p2p"]], ["name": "CH#2", "load": 10, "features": []]]],
            ["city": "Geneva", "servers": [["name": "CH#3", "load": 20, "features": ["tor"]]]],
        ]
        harness.fake.respondJSON("servers CH --json", cities)
        harness.fake.respond("servers JP --json", "nope")
        let vpn = harness.vpn
        #expect(vpn.cities("CH") == nil)
        await vpn.loadServers("CH")
        await vpn.loadServers("CH")
        await vpn.loadServers("JP")
        #expect(vpn.cities("CH")?.map(\.servers.count) == [2, 1])
        #expect(vpn.cities("JP") == nil)
        vpn.filters = ["p2p"]
        #expect(vpn.cities("CH") == nil)
        vpn.filters = []
        #expect(harness.fake.calls.filter { $0 == "servers CH --json" }.count == 1)
        vpn.forgetServers()
        #expect(vpn.cities("CH") == nil)
    }

    @Test func serverChoices() async {
        let harness = Harness()
        let cities: [[String: Any]] = [
            ["city": "Zurich", "servers": [["name": "CH#1", "load": 30, "features": []], ["name": "CH#2", "load": 10, "features": []]]],
            ["city": "Geneva", "servers": [["name": "CH#3", "load": 20, "features": []]]],
            ["city": "Bern", "servers": [["name": "CH#4", "load": 50, "features": []]]],
        ]
        harness.fake.respondJSON("servers CH --json", cities)
        let vpn = harness.vpn
        #expect(vpn.serverChoices == nil)
        vpn.status = Status(state: "Connected", server: "CH#1", code: "CH")
        vpn.countries = [switzerland]
        #expect(vpn.serverListKey == "CH[]falsefalse")
        await vpn.loadCurrentServers()
        let choices = vpn.serverChoices!
        #expect(choices.country == switzerland && choices.others.map(\.name) == ["CH#2", "CH#3", "CH#4"])
        #expect(choices.cities.map(\.name) == ["Zurich", "Geneva", "Bern"])
        #expect(choices.cities[0].servers?.map(\.name) == ["CH#2"] && choices.cities[1].servers == nil)

        vpn.connectFastest(choices)
        await eventually { vpn.busy == nil }
        vpn.connectRandom(choices)
        await eventually { vpn.busy == nil }
        vpn.connect(choices.cities[0], in: choices)
        await eventually { vpn.busy == nil }
        vpn.connect(choices.cities[1], in: choices)
        await eventually { vpn.busy == nil }
        let commands = harness.fake.calls.filter { $0.hasPrefix("CH#") || $0.hasPrefix("city") }
        #expect(commands[0] == "CH#2" && commands[2] == "CH#2" && commands[3] == "city Geneva")

        // On the only server in your city, it's left out.
        vpn.status = Status(state: "Connected", server: "CH#3", code: "CH")
        #expect(vpn.serverChoices?.cities.map(\.name) == ["Zurich", "Bern"])
        // Nothing to switch to while busy, or with no other server.
        vpn.busy = "Updating NetShield…"
        #expect(vpn.serverChoices == nil)
        vpn.busy = nil
        vpn.status = Status(state: "Connected", server: "CH#1")
        await vpn.loadCurrentServers()
        #expect(vpn.serverChoices == nil)
    }

    @Test func serverChoicesInACountryWithOneCityOrServer() async {
        let harness = Harness()
        harness.fake.respondJSON("servers JP --json", [["city": "Tokyo", "servers": [
            ["name": "JP#1", "load": 30, "features": []], ["name": "JP#2", "load": 10, "features": []]]]])
        harness.fake.respondJSON("servers UK --json", [["city": "London", "servers": [["name": "UK#1", "load": 30, "features": []]]]])
        let vpn = harness.vpn
        vpn.countries = [japan, unitedKingdom]
        vpn.status = Status(state: "Connected", server: "JP#1", code: "JP")
        await vpn.loadCurrentServers()
        #expect(vpn.serverChoices?.cities.isEmpty == true)
        vpn.status = Status(state: "Connected", server: "UK#1", code: "UK")
        await vpn.loadCurrentServers()
        #expect(vpn.serverChoices == nil)
    }

    @Test func theQuickConnectShortcutDoesWhatTheBigButtonDoes() async {
        let harness = Harness()
        harness.fake.respond("fastest", "", after: 5)
        let vpn = harness.vpn
        let calls = { harness.fake.calls.filter { !$0.contains("--json") } }
        // Disconnected: quick connects, here to the fastest; while connecting: cancels.
        vpn.quickConnectOrDisconnect()
        // Started, so there's something to cancel.
        await eventually { calls() == ["fastest"] }
        try? await Task.sleep(for: .milliseconds(200))
        vpn.status = Status(state: "Connecting", server: "CH#1", code: "CH")
        vpn.quickConnectOrDisconnect()
        await eventually { calls() == ["fastest", "off"] }
        await eventually { vpn.busy == nil }
        // Connected: disconnects, unless something's in progress.
        vpn.status = Status(state: "Connected", server: "CH#1", code: "CH")
        vpn.busy = "Turning NetShield off…"
        vpn.quickConnectOrDisconnect()
        vpn.busy = nil
        vpn.quickConnectOrDisconnect()
        await eventually { calls() == ["fastest", "off", "off"] }
        await eventually { vpn.busy == nil }
        // Disconnected but busy: waits.
        vpn.status = Status(state: "Disconnected")
        vpn.busy = "Signing out…"
        vpn.quickConnectOrDisconnect()
        #expect(calls() == ["fastest", "off", "off"])
    }

    @Test func quickConnectGoesToTheLastCountryOrTheFastest() async {
        let harness = Harness()
        let vpn = harness.vpn
        vpn.countries = [switzerland, japan]
        #expect(vpn.quickConnectCountry == nil)
        harness.defaults.set("JP", forKey: "lastCountry")
        #expect(vpn.quickConnectCountry == japan)
        vpn.filters = ["p2p"]
        #expect(vpn.quickConnectCountry == nil)
        vpn.quickConnect()
        await eventually { vpn.busy == nil }
        vpn.filters = []
        vpn.quickConnect()
        await eventually { vpn.busy == nil }
        vpn.account = Account(username: "me", plan: "Free", tier: 0)
        #expect(vpn.quickConnectCountry == nil)
        #expect(harness.fake.calls.filter { !$0.contains("--json") } == ["p2p fastest", "JP"])
    }

    @Test func settingsCommands() async {
        let harness = Harness()
        let vpn = harness.vpn
        let run = { (change: () -> Void) async in
            change()
            await eventually { vpn.busy == nil }
        }
        await run { vpn.setNetShield(1) }
        await run { vpn.setNetShield(0) }
        await run { vpn.setNetShield(3) }
        await run { vpn.setNetShield(9) }
        await run { vpn.setKillSwitch(false) }
        await run { vpn.setKillSwitch(true) }
        vpn.settings.killSwitch = 1
        await run { vpn.setKillSwitch(false) }
        await run { vpn.setDNS("proton") }
        await run { vpn.setDNS("cloudflare") }
        await run { vpn.setDNS("1.1.1.1") }
        await run { vpn.setPortForwarding(false) }
        await run { vpn.setPortForwarding(true) }
        #expect(harness.fake.calls.filter { !$0.contains("--json") } == [
            "set netshield off", "set netshield malware-ads-trackers-adult", "set kill-switch standard",
            "set kill-switch off", "dns cloudflare", "dns 1.1.1.1", "set port-forwarding on"])
    }

    @Test func signOutReloadsTheAccount() async {
        let harness = Harness()
        harness.fake.respond("account --json", "null")
        let vpn = harness.vpn
        vpn.account = Account(username: "me", plan: "Plus", tier: 2)
        vpn.signOut()
        #expect(vpn.busy == "Signing out…")
        vpn.signOut()
        await eventually { vpn.busy == nil && vpn.account == nil }
        #expect(harness.fake.calls.filter { $0 == "signout" }.count == 1)
    }

    @Test func accountKeepsTheLastOneIfTheCLIFails() async {
        let harness = Harness()
        harness.fake.respondJSON("account --json", ["username": "me", "plan": "Plus", "tier": 2])
        let vpn = harness.vpn
        await vpn.loadAccount()
        #expect(vpn.account?.username == "me" && vpn.accountLoaded)
        harness.fake.respond("account --json", "", status: 1)
        await vpn.loadAccount()
        #expect(vpn.account?.username == "me")
    }

    @Test func setupChecksAndRunsAsAdministrator() async {
        let harness = Harness()
        harness.fake.respond("setup --check", "", status: 1)
        let vpn = harness.vpn
        await vpn.checkSetup()
        #expect(vpn.needsSetup)
        harness.admin.result = (false, "Wrong password")
        vpn.runSetup()
        #expect(vpn.busy == "Setting up…")
        await eventually { vpn.busy == nil && vpn.message == "Wrong password" }
        #expect(harness.admin.commands == ["'\(harness.fake.path)' setup --user \(NSUserName())"])
        vpn.message = nil
        harness.admin.result = (false, "User canceled.")
        vpn.runSetup()
        await eventually { vpn.busy == nil }
        #expect(vpn.message == nil)
        harness.fake.respond("setup --check")
        harness.admin.result = (true, "")
        vpn.runSetup()
        await eventually { !vpn.needsSetup }
    }

    @Test func openAtLogin() {
        let harness = Harness()
        let vpn = harness.vpn
        vpn.setOpenAtLogin(true)
        #expect(vpn.openAtLogin && harness.loginItem.enabled)
        vpn.setOpenAtLogin(false)
        #expect(!vpn.openAtLogin)
        harness.loginItem.failure = Failure()
        vpn.setOpenAtLogin(true)
        #expect(vpn.message == "Couldn't change Open at Login: it failed" && !vpn.openAtLogin)
    }
}
