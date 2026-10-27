import ServiceManagement
import SwiftUI

@main
struct ProtonVPNMenuBar: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var vpn = VPN.shared

    var body: some Scene {
        MenuBarExtra {
            Panel(vpn: vpn)
        } label: {
            Image(nsImage: vpn.icon)
        }
        .menuBarExtraStyle(.window)
    }
}

extension VPN {
    static let shared: VPN = {
        let vpn = VPN(environment: .live)
        vpn.onAlert = vpn.showAlert
        vpn.onUpdateAvailable = vpn.offerUpdate
        vpn.start()
        return vpn
    }()
}

extension AppEnvironment {
    /// The real `protonvpn`, Proton's folders in your home, and the system's network, login items and
    /// administrator prompt.
    static let live: AppEnvironment = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AppEnvironment(
            vpnPath: findVPN(home: home.path, configured: UserDefaults.standard.string(forKey: "vpnPath"),
                             isExecutable: FileManager.default.isExecutableFile(atPath:)),
            connectionDirectory: home.appendingPathComponent(".cache/Proton/VPN/connection").path,
            settingsDirectory: home.appendingPathComponent(".config/Proton/VPN").path,
            forwardedPortDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("Proton/VPN").path,
            defaults: .standard,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            fetch: { try await URLSession.shared.data(for: $0) },
            loginItem: MainAppLoginItem(),
            runAsAdministrator: { command in
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        var error: NSDictionary?
                        let script = "do shell script \"\(command)\" with administrator privileges"
                        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
                        continuation.resume(returning: (error == nil, result?.stringValue ?? (error?[NSAppleScript.errorMessage] as? String ?? "")))
                    }
                }
            })
    }()
}

struct MainAppLoginItem: LoginItem {
    var enabled: Bool { SMAppService.mainApp.status == .enabled }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
