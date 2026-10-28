import AppKit
import Foundation
import Testing
@testable import ProtonVPNMenuBar

@MainActor @Suite struct VPNStateTests {
    @Test func readsAndSavesItsPreferences() {
        let harness = Harness { defaults in
            defaults.set(["JP"], forKey: "pinned")
            defaults.set(["US"], forKey: "recents")
            defaults.set(true, forKey: "secureCore")
            defaults.set(["p2p"], forKey: "filters")
            defaults.set(true, forKey: "autoConnect")
            defaults.set(false, forKey: "showFlag")
        }
        let vpn = harness.vpn
        #expect(vpn.pinnedCodes == ["JP"] && vpn.recentCodes == ["US"] && vpn.secureCore && vpn.filters == ["p2p"])
        #expect(vpn.autoConnect && !vpn.showFlag && !vpn.openAtLogin)
        vpn.togglePin("CH")
        vpn.togglePin("JP")
        vpn.setSecureCore(false)
        vpn.filters = ["tor"]
        vpn.autoConnect = false
        vpn.showFlag = true
        vpn.recentCodes = ["DE"]
        let defaults = harness.defaults
        #expect(defaults.stringArray(forKey: "pinned") == ["CH"])
        #expect(defaults.stringArray(forKey: "recents") == ["DE"])
        #expect(!defaults.bool(forKey: "secureCore") && defaults.stringArray(forKey: "filters") == ["tor"])
        #expect(!defaults.bool(forKey: "autoConnect") && defaults.bool(forKey: "showFlag"))
    }

    @Test func quittingDoesWhatYouSaidNotToAskAgainAbout() {
        let harness = Harness { $0.set(true, forKey: "disconnectOnQuit") }
        let vpn = harness.vpn
        #expect(vpn.askToQuit() == .quit)
        vpn.status = Status(state: "Connected", server: "CH#1", code: "CH")
        #expect(vpn.askToQuit() == .disconnectAndQuit)
        vpn.disconnectOnQuit = false
        #expect(vpn.askToQuit() == .quit && harness.defaults.object(forKey: "disconnectOnQuit") as? Bool == false)
        vpn.disconnectOnQuit = nil
        #expect(harness.defaults.object(forKey: "disconnectOnQuit") == nil)
    }

    @Test func defaultsWithoutPreferences() {
        let vpn = Harness().vpn
        #expect(vpn.pinnedCodes == [] && vpn.recentCodes == defaultRecents && !vpn.secureCore && vpn.filters == [])
        #expect(!vpn.autoConnect && vpn.showFlag)
    }

    @Test func recentsArePinnedThenRecentCountries() {
        let vpn = Harness().vpn
        vpn.countries = [switzerland, unitedStates, unitedKingdom, japan]
        vpn.pinnedCodes = ["JP", "UK"]
        vpn.recentCodes = ["UK", "CH", "XX"]
        #expect(vpn.recents.map(\.code) == ["JP", "UK", "CH"])
    }

    @Test func remembersNewCountriesWithoutShuffling() {
        let harness = Harness { $0.set(["CH", "UK", "US", "DE", "FR", "NL"], forKey: "recents") }
        let vpn = harness.vpn
        vpn.status = Status(state: "Connected", server: "UK#1", code: "UK")
        #expect(vpn.recentCodes == ["CH", "UK", "US", "DE", "FR", "NL"])
        vpn.status = Status(state: "Connected", server: "JP#1", code: "JP")
        #expect(vpn.recentCodes == ["JP", "CH", "UK", "US", "DE", "FR"])
        #expect(harness.defaults.string(forKey: "lastCountry") == "JP")
    }

    @Test func activeCountry() {
        let vpn = Harness().vpn
        #expect(vpn.activeCode == nil && vpn.activeState == "Disconnected")
        vpn.status = Status(state: "Connecting", server: "IS-CH#1")
        #expect(vpn.activeCode == "CH")
        vpn.status = Status(state: "Connecting", server: "CH#871")
        #expect(vpn.activeCode == "CH")
        vpn.status = Status(state: "Connecting")
        #expect(vpn.activeCode == nil)
        vpn.status = Status(state: "Connected", server: "US-IL#352", code: "US")
        #expect(vpn.activeCode == "US" && vpn.activeState == "Connected")
        vpn.connectingCode = "JP"
        #expect(vpn.activeCode == "JP" && vpn.activeState == "Connecting")
    }

    @Test func aStatusChangeClearsTheMessageAndFinishesDisconnecting() {
        let vpn = Harness().vpn
        vpn.status = Status(state: "Connected", server: "CH#1", code: "CH")
        vpn.message = "Failed"
        vpn.busy = "Disconnecting…"
        vpn.status = Status(state: "Disconnected")
        #expect(vpn.message == nil && vpn.busy == nil)
        // An unchanged status keeps it.
        vpn.message = "Failed"
        vpn.status = Status(state: "Disconnected")
        #expect(vpn.message == "Failed")
    }

    @Test func modesFollowSecureCoreFiltersAndPortForwarding() async {
        let harness = Harness()
        let vpn = harness.vpn
        vpn.countries = [switzerland]
        vpn.fastest()
        await eventually { vpn.busy == nil }
        vpn.filters = ["tor", "p2p"]
        vpn.random()
        await eventually { vpn.busy == nil }
        vpn.filters = []
        vpn.settings.portForwarding = true
        vpn.connect(switzerland)
        await eventually { vpn.busy == nil }
        vpn.setSecureCore(true)
        vpn.connect(city: "Zurich", in: switzerland)
        await eventually { vpn.busy == nil }
        let commands = harness.fake.calls.filter { !$0.hasPrefix("status") && !$0.hasPrefix("settings") && !$0.hasPrefix("list") }
        #expect(commands == ["fastest", "tor p2p random", "p2p CH", "city sc Zurich"])
    }

    @Test func availableCountriesForTheMode() {
        let vpn = Harness().vpn
        let all = [switzerland, unitedStates, unitedKingdom, japan]
        #expect(vpn.available(all).count == 4)
        vpn.filters = ["streaming"]
        #expect(vpn.available(all).map(\.code) == ["CH", "UK"])
        vpn.filters = []
        vpn.settings.portForwarding = true
        #expect(vpn.available(all).map(\.code) == ["CH", "US"])
        vpn.secureCore = true
        #expect(vpn.available(all).map(\.code) == ["CH"])
    }

    @Test func searchRanksLikeTheCLI() {
        let vpn = Harness().vpn
        let curacao = Country(code: "CW", name: "Curaçao", servers: 1, aliases: [], features: [], combos: nil)
        let tonga = Country(code: "TO", name: "Tonga", servers: 1, aliases: [], features: [], combos: nil)
        vpn.countries = [unitedStates, unitedKingdom, switzerland, curacao, tonga]
        #expect(vpn.search("  ").isEmpty)
        #expect(vpn.search("uk").map(\.code) == ["UK"])
        #expect(vpn.search("united").map(\.code) == ["UK", "US"])
        #expect(vpn.search("swi").map(\.code) == ["CH"])
        #expect(vpn.search("brit").map(\.code) == ["UK"])
        #expect(vpn.search("kingdom").map(\.code) == ["UK"])
        #expect(vpn.search("curacao").map(\.code) == ["CW"])
        #expect(vpn.search("on").map(\.code) == ["TO"])
        #expect(vpn.search("zz").isEmpty)
    }

    @Test func listsRecentsFilteredCountriesOrSearchResults() {
        let vpn = Harness().vpn
        vpn.countries = [unitedStates, unitedKingdom, switzerland, japan]
        vpn.recentCodes = ["UK", "CH"]
        #expect(vpn.listed(query: "").map(\.code) == ["UK", "CH"])
        #expect(vpn.restStart(query: "") == nil)
        #expect(vpn.listed(query: "uni").map(\.code) == ["UK", "US"])
        vpn.filters = ["p2p"]
        #expect(vpn.listed(query: "").map(\.code) == ["CH", "US"])
        #expect(vpn.restStart(query: "") == 1)
        #expect(vpn.restStart(query: "u") == nil)
        vpn.recentCodes = []
        #expect(vpn.restStart(query: "") == nil)
        vpn.recentCodes = ["CH", "US"]
        #expect(vpn.restStart(query: "") == nil)
    }

    @Test func dnsLabel() {
        let vpn = Harness().vpn
        #expect(vpn.dnsLabel == "Proton")
        vpn.settings.dns = "1.2.3.4"
        #expect(vpn.dnsLabel == "Custom")
    }

    @Test func busyTitleSaysWhereItsConnecting() {
        let vpn = Harness().vpn
        #expect(vpn.busyTitle("Connecting…") == "Connecting…")
        vpn.status = Status(state: "Connecting", server: "JP#1", code: "JP", country: "Japan")
        #expect(vpn.busyTitle("Connecting…") == "Connecting to Japan…")
        #expect(vpn.busyTitle("Reconnecting…") == "Connecting to Japan…")
        #expect(vpn.busyTitle("Turning NetShield off…") == "Turning NetShield off…")
    }

    @Test func busyTitleKeepsAPickedCityOrServer() {
        let vpn = Harness().vpn
        vpn.status = Status(state: "Connecting", server: "JP#1", code: "JP", country: "Japan")
        #expect(vpn.busyTitle("Connecting to Tokyo…") == "Connecting to Tokyo…")
        #expect(vpn.busyTitle("Connecting to JP#1…") == "Connecting to JP#1…")
    }

    @Test func marksThePickedCityOrServer() {
        let harness = Harness()
        harness.fake.respond("city Tokyo", "", after: 5)
        let vpn = harness.vpn
        let tokyo = { (city: String?, server: String?) in vpn.isActive(code: "JP", city: city, server: server) }
        // Picked: marked straight away, before the connection says where it is.
        vpn.connect(city: "Tokyo", in: japan, picked: true)
        #expect(vpn.pick == VPN.Pick(code: "JP", city: "Tokyo"))
        #expect(tokyo("Tokyo", nil) && !tokyo("Osaka", nil) && !tokyo(nil, "JP#1"))
        #expect(!vpn.isActive(code: "CH", city: "Tokyo"))
        vpn.connectingCode = nil
        // Connected: the server it's on, and the city only if it was picked.
        vpn.status = Status(state: "Connected", server: "JP#1", code: "JP", city: "Tokyo")
        #expect(tokyo(nil, "JP#1") && !tokyo(nil, "JP#2"))
        #expect(tokyo("Tokyo", nil))
        vpn.pick = nil
        #expect(!tokyo("Tokyo", nil))
        vpn.status = Status(state: "Disconnected")
        #expect(!tokyo(nil, "JP#1"))
    }

    @Test func connectingAnyOtherWayForgetsThePick() async {
        let harness = Harness()
        let vpn = harness.vpn
        let server = Server(name: "JP#1", load: 1, entry: nil, features: [])
        vpn.connect(server: server, in: japan, picked: true)
        #expect(vpn.pick == VPN.Pick(code: "JP", server: "JP#1"))
        await eventually { vpn.busy == nil }
        vpn.connect(server: server, in: japan)
        #expect(vpn.pick == nil)
        await eventually { vpn.busy == nil }
        for connect in [{ vpn.connect(japan) }, { vpn.fastest() }, { vpn.random() }] {
            vpn.pick = VPN.Pick(code: "JP", city: "Tokyo")
            connect()
            #expect(vpn.pick == nil)
            await eventually { vpn.busy == nil }
        }
    }

    @Test func iconFollowsTheConnection() {
        resourceDirectory = repoResources
        let vpn = Harness().vpn
        #expect(vpn.icon === MenuBarIcon.disconnected)
        vpn.message = "Failed"
        #expect(vpn.icon === MenuBarIcon.error)
        vpn.status = Status(state: "Dropped", server: "CH#1")
        #expect(vpn.icon === MenuBarIcon.error)
        vpn.status = Status(state: "Connected", server: "CH#1", code: "CH")
        #expect(vpn.icon === MenuBarIcon.flagged("CH"))
        vpn.showFlag = false
        #expect(vpn.icon === MenuBarIcon.connected)
        vpn.status = Status(state: "Connected", server: "CH#1")
        vpn.showFlag = true
        #expect(vpn.icon === MenuBarIcon.connected)
        vpn.busy = "Connecting…"
        #expect(MenuBarIcon.connecting.contains { $0 === vpn.icon })
        vpn.busy = nil
    }

    @Test func animatesWhileConnecting() async {
        resourceDirectory = repoResources
        let vpn = Harness().vpn
        vpn.status = Status(state: "Connecting", server: "CH#1")
        #expect(vpn.connecting)
        let first = vpn.icon
        await eventually({ vpn.icon !== first }, timeout: 2)
        vpn.busy = "Connecting…"
        vpn.status = Status(state: "Connected", server: "CH#1", code: "CH")
        vpn.busy = nil
        #expect(!vpn.connecting)
    }

    @Test func identifiesModels() {
        #expect(switzerland.id == "CH")
        #expect(Server(name: "CH#1", load: 10, entry: nil, features: []).id == "CH#1")
        #expect(City(city: "Zurich", servers: []).id == "Zurich")
    }
}
