import AppKit
import ServiceManagement
import SystemConfiguration
import SwiftUI

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// How many of a city's servers to show at a time, least loaded first.
let serverPage = 8

/// Proton's pinkish red for "Not Connected".
let notConnected = Color(red: 0.91, green: 0.42, blue: 0.47)

/// A full-width row that highlights on hover, like a menu item.
struct HoverButton<Label: View>: View {
    var highlighted = false
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
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering || highlighted ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain).pointingHand()
        .onHover { hovering = $0 }
    }
}

struct FeatureIcons: View {
    let features: [String]

    var body: some View {
        HStack(spacing: 5) {
            if features.contains("p2p") { Image(systemName: "arrow.left.arrow.right").tip(featureTips["p2p"]!) }
            if features.contains("tor") { Image(nsImage: resource("ic-brand-tor")).resizable().frame(width: 12, height: 12).tip(featureTips["tor"]!) }
            if features.contains("streaming") { Image(systemName: "play").tip(featureTips["streaming"]!) }
            if features.contains("smartrouting") { Image(systemName: "globe").tip(featureTips["smartrouting"]!) }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
}

struct CountryRow: View {
    let country: Country
    var highlighted = false
    let pinned: Bool
    let togglePin: () -> Void
    let expanded: Bool
    let toggleExpanded: () -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HoverButton(highlighted: highlighted, action: action) {
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
        .buttonStyle(.plain).pointingHand()
        .tip(expanded ? "Hide servers" : "Show servers")
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
                LoadBar(load: server.load)
            }
        }
        .padding(.leading, 16)
    }
}

/// A server's load, colored like Proton's: green, then yellow from 75%, red from 90%.
struct LoadBar: View {
    let load: Int

    var body: some View {
        Capsule().fill(Color.primary.opacity(0.12)).frame(width: 28, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(load < 75 ? .green : load < 90 ? .yellow : .red)
                    .frame(width: 28 * CGFloat(min(load, 100)) / 100, height: 4)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .tip("Load: \(load)%")
    }
}

/// Copies a value, such as the forwarded port, to the clipboard.
struct CopyButton: View {
    let value: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.plain).pointingHand().tip("Copy")
    }
}

/// A feature filter beside the search field.
struct FilterButton: View {
    let feature: String
    let title: String
    let image: Image
    let tip: String
    let selected: Bool
    /// On because another setting needs it, so it can't be turned off.
    var locked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .padding(4)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 5).fill(locked ? Color.primary.opacity(0.2) : selected ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand()
        .tip(tip)
    }
}

extension View {
    /// A tooltip: `help` doesn't show in a menu bar panel, as the app's never active.
    func tip(_ text: String) -> some View { modifier(Tip(text: text)) }
}

struct Tip: ViewModifier {
    let text: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                TipWindow.shared.hide()
                guard inside else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if hovering, !text.isEmpty { TipWindow.shared.show(text) }
                }
            }
            .onDisappear {
                if hovering { TipWindow.shared.hide() }
            }
    }
}

/// The tooltip itself, in a window of its own under the pointer, so nothing in the panel clips or
/// covers it.
@MainActor final class TipWindow {
    static let shared = TipWindow()
    private let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    private init() {
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.contentView = host
        // Out of the way of a click, and of any menu it opens, such as DNS's.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.hide()
            return event
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.menuOpen = true
                self.hide()
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.menuOpen = false }
        }
    }

    private var menuOpen = false

    func show(_ text: String) {
        guard !menuOpen else { return }
        host.rootView = AnyView(
            Text(text)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                .fixedSize()
        )
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x, y: mouse.y - size.height - 20)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width - 4)
        }
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFront(nil)
    }

    func hide() { window.orderOut(nil) }
}

/// A star that pins a country to the top of the list: always shown once pinned, otherwise on hover.
struct PinButton: View {
    let pinned: Bool
    let visible: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: pinned ? "star.fill" : "star")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 12)
        }
        .buttonStyle(.plain).pointingHand()
        .focused($focused)
        // Also shown when the keyboard focuses it, so pinning doesn't need a mouse.
        .opacity(pinned || visible || focused ? 1 : 0)
        .tip(pinned ? "Unpin" : "Pin to the top")
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
        .buttonStyle(.plain).pointingHand()
        .onHover { hovering = $0 }
        .tip(state == "Connecting" ? "Cancel" : "Disconnect")
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
    let text = { (string: String) in NSAttributedString(string: string) }
    // The Alfred workflow is only worth mentioning to people who have Alfred.
    let alfred = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.runningwithcrayons.Alfred") != nil
    let lines: [[NSAttributedString]] = [
        [text("A small menu bar app for Proton VPN, compatible with the "),
         link("Proton VPN CLI for macOS", "https://github.com/stevelacey/proton-vpn-cli-macos"), text(".")],
        alfred ? [text(" There's also an "), link("Alfred workflow", "https://github.com/stevelacey/alfred-proton-vpn"), text(".")] : [],
        [text("\n\n")],
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
    /// A pointing hand over anything clickable, as on a web page.
    @ViewBuilder func pointingHand() -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.link)
        } else {
            onHover { inside in inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
    }

    /// The header's lines have fixed heights, so the panel doesn't change height between states.
    func titleLine() -> some View { frame(height: 24, alignment: .leading) }
    func infoLine() -> some View { frame(height: 20, alignment: .leading) }
}

/// Each setting's icons, the same on its toggle and in its card.
enum Icon {
    static func secureCore(_ on: Bool) -> Image { Image(nsImage: resource(on ? "ic-lock-filled" : "ic-lock")) }
    static func killSwitch(_ on: Bool) -> Image { Image(nsImage: resource(on ? "ic-killswitch-on" : "ic-killswitch")) }
    static func portForwarding(_ on: Bool) -> Image {
        Image(nsImage: resource(on ? "ic-arrows-switch" : "ic-arrow-up-bounce-left"))
    }
    /// Proton's shields, plus one with a check for adult content, which Proton's icons don't have.
    static func netShield(_ level: Int) -> Image {
        switch level {
        case 1: Image(nsImage: resource("ic-shield-half-filled"))
        case 2: Image(nsImage: resource("ic-shield-filled"))
        case 3: Image(systemName: "checkmark.shield.fill")
        default: Image(nsImage: resource("ic-shield"))
        }
    }
}

/// A feature's card, like the popovers in Proton's app: what it does, and its settings to pick from.
struct FeatureCard: View {
    @ObservedObject var vpn: VPN
    let feature: VPN.Feature

    struct Option {
        let title: String
        let image: Image
        let selected: Bool
        var enabled = true
        let choose: () -> Void
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .onTapGesture { vpn.card = nil }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(content.title).font(.headline)
                    Spacer()
                    Button { vpn.card = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).pointingHand()
                        .foregroundStyle(.secondary)
                        .tip("Close")
                }
                Text(content.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) {
                    ForEach(content.options.indices, id: \.self) { index in
                        OptionRow(option: content.options[index]) { vpn.card = nil }
                    }
                }
                if feature == .portForwarding, let port = vpn.status.port {
                    // Like Proton's: the port in a box of its own, ready to copy.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Active port number").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(.green).frame(width: 10, height: 10)
                            Text(String(port)).font(.title2.weight(.medium)).monospacedDigit().textSelection(.enabled)
                            CopyButton(value: String(port)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
                if let note = content.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            .padding(16)
        }
    }

    var content: (title: String, text: String, options: [Option], note: String?) {
        switch feature {
        case .secureCore:
            return ("Secure Core",
                    "Routes your connection through a second server in Switzerland, Iceland or Sweden first, so even a compromised server can't see where you're from.",
                    [Option(title: "Secure Core Off", image: Icon.secureCore(false), selected: !vpn.secureCore) { vpn.setSecureCore(false) },
                     Option(title: "Secure Core On", image: Icon.secureCore(true), selected: vpn.secureCore) { vpn.setSecureCore(true) }],
                    "Secure Core may reduce your speed.")
        case .netShield:
            let usable = vpn.settings.dns == "proton"
            return ("NetShield",
                    "Blocks malware, and if you like ads, trackers and adult content, by filtering Proton's DNS.",
                    NetShieldLevel.all.map { level in
                        Option(title: level.title, image: Icon.netShield(level.level),
                               selected: (usable ? vpn.settings.netshield : 0) == level.level,
                               enabled: usable || level.level == 0) { vpn.setNetShield(level.level) }
                    },
                    usable ? "If websites don't load, try turning NetShield off."
                           : "NetShield only works with Proton's DNS. Pick it in the DNS menu to use NetShield.")
        case .killSwitch:
            let on = vpn.settings.killSwitch > 0
            return ("Kill Switch",
                    "If the VPN connection drops, the kill switch blocks your internet until it's back, so your real IP address can't leak. Your local network keeps working.",
                    [Option(title: "Kill Switch Off", image: Icon.killSwitch(false), selected: !on) { vpn.setKillSwitch(false) },
                     Option(title: "Kill Switch On", image: Icon.killSwitch(true), selected: on) { vpn.setKillSwitch(true) }],
                    "Your IP address may be visible for a moment while switching servers.")
        case .portForwarding:
            let on = vpn.settings.portForwarding
            return ("Port Forwarding",
                    "Lets incoming connections reach you through the VPN, for torrenting, games and hosting. It only works on P2P servers, so you'll connect to one.",
                    [Option(title: "Port Forwarding Off", image: Icon.portForwarding(false), selected: !on) { vpn.setPortForwarding(false) },
                     Option(title: "Port Forwarding On", image: Icon.portForwarding(true), selected: on) { vpn.setPortForwarding(true) }],
                    vpn.status.port != nil ? "Enter the active port number into your BitTorrent app to improve your P2P speeds."
                        : "Only use it with apps you trust: the port is open to the internet.")
        }
    }
}

/// One of a feature card's settings: highlighted when it's the current one.
struct OptionRow: View {
    let option: FeatureCard.Option
    let done: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            option.choose()
            done()
        } label: {
            HStack(spacing: 10) {
                option.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text(option.title)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if option.selected {
                    Image(systemName: "checkmark").fontWeight(.semibold)
                }
            }
            .foregroundStyle(option.enabled ? Color.primary : Color.secondary.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // The chosen one is tinted, keeping its text readable.
            .background(RoundedRectangle(cornerRadius: 8).fill(option.selected
                ? Color.accentColor.opacity(0.25)
                : Color.primary.opacity(hovering && option.enabled ? 0.1 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(option.selected ? Color.accentColor : Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand()
        .disabled(!option.enabled)
        .onHover { hovering = $0 }
    }
}

/// Quitting, whether from the power button or Cmd-Q, asks first while connected.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let vpn = VPN.shared
            switch vpn.askToQuit() {
            case .quit:
                return .terminateNow
            case .cancel:
                return .terminateCancel
            case .disconnectAndQuit:
                vpn.busy = "Disconnecting…"
                Task {
                    _ = await vpn.command(["off"])
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }
        }
    }
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
                    .buttonStyle(.plain).pointingHand().foregroundStyle(.secondary).tip("Quit")
            }
            Text("This app runs on the Proton VPN CLI for macOS. Install it with Homebrew:")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                CopyButton(value: command)
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
                    .buttonStyle(.plain).pointingHand().foregroundStyle(.secondary).tip("Quit")
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
                    .buttonStyle(.plain).pointingHand()
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
                Text("Signs in with the Proton VPN CLI for macOS, straight to Proton. Your password isn't stored; the session is kept in your Keychain.")
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
        .buttonStyle(.plain).pointingHand()
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
            ToggleFace(title: title, image: image, on: on, hovering: hovering && enabled)
        }
        .buttonStyle(.plain).pointingHand()
        .onHover { hovering = $0 && enabled }
    }
}

/// How a quick setting looks: its icon and name, filled when it's on.
struct ToggleFace: View {
    let title: String
    let image: Image
    let on: Bool
    var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
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
}

/// NetShield, which has levels rather than just on and off.

/// Quick Connect while disconnected (to the last country, with the current filters); Cancel while
/// connecting and Disconnect once connected, in its place.
struct QuickConnectButton: View {
    @ObservedObject var vpn: VPN

    var body: some View {
        switch vpn.activeState {
        case "Disconnected":
            ActionButton(title: "Quick Connect", symbol: "bolt.horizontal.fill", style: .primary) { vpn.quickConnect() }
                .disabled(vpn.busy != nil)
        case "Connecting":
            ActionButton(title: "Cancel", symbol: "xmark") { vpn.disconnect() }
        default:
            ActionButton(title: "Disconnect", symbol: "bolt.slash.fill", style: .destructive) { vpn.disconnect() }
                .disabled(vpn.busy != nil)
        }
    }
}

struct ActionButton: View {
    enum Style { case plain, primary, destructive }

    let title: String
    let symbol: String
    var style = Style.plain
    let action: () -> Void
    @State private var hovering = false

    /// Primary is always filled; destructive only turns red when you point at it.
    var fill: Color {
        switch style {
        case .primary: return Color.accentColor.opacity(hovering ? 0.85 : 1)
        case .destructive where hovering: return Color(red: 0.85, green: 0.27, blue: 0.33)
        default: return Color.primary.opacity(hovering ? 0.12 : 0.06)
        }
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .foregroundStyle(style == .primary || (style == .destructive && hovering) ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        }
        .buttonStyle(.plain).pointingHand()
        .onHover { hovering = $0 }
    }
}


/// The app's side of `VPN`: the panel and the alerts it shows.
extension VPN {
    /// Closes the menu bar panel (for Escape). It's closed by clicking the menu bar item, as you would,
    /// since closing the window itself leaves the item highlighted and the next click only closes
    /// what's already gone.
    func closePanel() {
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

    enum QuitChoice { case quit, disconnectAndQuit, cancel }

    /// Asks, while connected, whether to leave the VPN on (the CLI and Alfred can still use it) or
    /// disconnect before quitting.
    func askToQuit() -> QuitChoice {
        guard status.state != "Disconnected" else { return .quit }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit Proton VPN Menu Bar?"
        alert.informativeText = "You're connected to \(status.server ?? "Proton VPN"). It stays connected after quitting, unless you disconnect."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Disconnect and Quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .quit
        case .alertSecondButtonReturn: return .disconnectAndQuit
        default: return .cancel
        }
    }

    func offerUpdate() {
        guard let update else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Proton VPN Menu Bar \(update.version) is available"
        alert.informativeText = "You have \(environment.version). If you installed it with Homebrew, run `brew upgrade`; otherwise download the new version."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(update.url) }
    }

    func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

}
