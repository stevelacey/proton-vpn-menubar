import AppKit
import Foundation
import Testing
@testable import ProtonVPNMenuBar

@Test func findsVPNWhereverItIsInstalled() {
    let installed: Set = ["/custom/vpn", "/usr/local/bin/vpn", "/Users/me/.local/bin/vpn"]
    let find = { (configured: String?, have: Set<String>) in
        AppEnvironment.findVPN(home: "/Users/me", configured: configured, isExecutable: have.contains)
    }
    #expect(find("/custom/vpn", installed) == "/custom/vpn")
    #expect(find(nil, installed) == "/usr/local/bin/vpn")
    #expect(find(nil, ["/Users/me/.local/bin/vpn"]) == "/Users/me/.local/bin/vpn")
    #expect(find(nil, []) == "/opt/homebrew/bin/vpn")
}

@MainActor @Test func knowsWhetherTheCLIIsInstalled() {
    let harness = Harness()
    #expect(harness.vpn.environment.cliInstalled)
    var missing = harness.vpn.environment
    missing.vpnPath = "/nowhere/vpn"
    #expect(!missing.cliInstalled)
}

@Test func freeAccountsAreTierZero() {
    #expect(Account(username: "me", plan: "Free", tier: 0).free)
    #expect(!Account(username: "me", plan: "Plus", tier: 2).free)
    #expect(!Account(username: "me", plan: "Plus", tier: nil).free)
}

@Test func countriesHaveServersWithFeaturesTogether() {
    #expect(switzerland.hasServer(with: ["p2p", "streaming"]))
    #expect(!switzerland.hasServer(with: ["p2p", "securecore"]))
    // Without combinations, any of the country's features count.
    #expect(unitedKingdom.hasServer(with: ["streaming"]))
    #expect(!unitedKingdom.hasServer(with: ["tor"]))
}

@Test func lineBufferSplitsOutputIntoLines() {
    let buffer = LineBuffer()
    #expect(buffer.append(Data("2f".utf8)) == [])
    #expect(buffer.append(Data("a\nok me\npart".utf8)) == ["2fa", "ok me"])
    #expect(buffer.append(Data("ial\n".utf8)) == ["partial"])
}

@Test func runsVPNAndReportsItsOutput() async {
    let fake = FakeVPN()
    fake.respond("status --json", "{}\n", status: 3)
    let started = Mutex(false)
    let (code, output) = await runVPN(fake.path, ["status", "--json"]) { _ in started.set(true) }
    #expect(code == 3 && output == "{}\n" && started.value)
    #expect(fake.calls == ["status --json"])
}

@Test func reportsWhenVPNCantRun() async {
    let (code, output) = await runVPN("/nowhere/vpn", ["status"])
    #expect(code == -1)
    #expect(output.hasPrefix("Couldn't run /nowhere/vpn: "))
}

@Test func flagsFromCountryCodes() {
    #expect(flag("CH") == "🇨🇭")
    #expect(flag("UK") == "🇬🇧")
}

@Test func foldsCaseAndAccents() {
    #expect(fold("Curaçao") == "curacao")
}

@Test func loadsImagesFromTheResources() {
    resourceDirectory = repoResources
    #expect(resource("connected").isTemplate)
    #expect(resource("ic-lock").size.width > 0)
    #expect(!resource("AppIcon", template: false).isTemplate)
    #expect(resource("missing").size == .zero)
}

@Test func formatsRates() {
    #expect(rate(0) == "0 KB/s")
    #expect(rate(2_480_000) == "2.5 MB/s")
}

@Test func netShieldLevelsAndFeatureTips() {
    #expect(NetShieldLevel.all.map(\.value) == ["off", "malware-only", "malware-ads-trackers", "malware-ads-trackers-adult"])
    #expect(featureTips["p2p"] == "P2P: best for BitTorrent and file sharing")
}

/// A value shared with a closure that runs on another thread.
final class Mutex<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}
