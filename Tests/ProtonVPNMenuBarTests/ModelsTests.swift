import AppKit
import Foundation
import Testing
@testable import ProtonVPNMenuBar

@Test func findsVPNWhereverItIsInstalled() {
    let installed: Set = ["/custom/protonvpn", "/usr/local/bin/protonvpn", "/Users/me/.local/bin/protonvpn"]
    let find = { (configured: String?, have: Set<String>) in
        AppEnvironment.findVPN(home: "/Users/me", configured: configured, isExecutable: have.contains)
    }
    #expect(find("/custom/protonvpn", installed) == "/custom/protonvpn")
    #expect(find(nil, installed) == "/usr/local/bin/protonvpn")
    #expect(find(nil, ["/Users/me/.local/bin/protonvpn"]) == "/Users/me/.local/bin/protonvpn")
    #expect(find(nil, []) == "/opt/homebrew/bin/protonvpn")
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

@Test func shortcutsNeedAModifierAndShowLikeMacOS() {
    #expect(Shortcut(keyCode: 9, modifiers: [], characters: "v") == nil)
    #expect(Shortcut(keyCode: 9, modifiers: .shift, characters: "V") == nil)
    #expect(Shortcut(keyCode: 9, modifiers: .command, characters: "") == nil)
    let shortcut = Shortcut(keyCode: 9, modifiers: [.command, .option, .capsLock], characters: "v")!
    #expect(shortcut.description == "⌥⌘V")
    #expect(shortcut.carbonModifiers == 256 | 2048)
    let all = Shortcut(keyCode: 49, modifiers: [.control, .option, .shift, .command], characters: " ")!
    #expect(all.description == "⌃⌥⇧⌘Space")
    #expect(all.carbonModifiers == 256 | 512 | 2048 | 4096)
}

@MainActor @Test func theShortcutIsKeptAndRegistered() {
    let harness = Harness()
    var registered = 0
    harness.vpn.onShortcutChange = { registered += 1 }
    let shortcut = Shortcut(keyCode: 9, modifiers: .command, characters: "v")
    let quick = Shortcut(keyCode: 2, modifiers: .option, characters: "d")
    harness.vpn.shortcut = shortcut
    harness.vpn.quickShortcut = quick
    #expect(registered == 2)
    let reloaded = VPN(environment: harness.vpn.environment)
    #expect(reloaded.shortcut == shortcut && reloaded.quickShortcut == quick)
    harness.vpn.shortcut = nil
    #expect(VPN(environment: harness.vpn.environment).shortcut == nil)
    // The default does nothing.
    reloaded.onShortcutChange()
}
