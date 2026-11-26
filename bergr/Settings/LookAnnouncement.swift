import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Tells existing users, once, that themes arrived with this update: a small sheet on the main
/// screen offering Miami. One flag, not per look; it never shows again after either button.
enum LookAnnouncement {
    static let key = "themes.announced"
    /// The look the sheet offers.
    static let look = AppLook.miami

    /// Demo, screenshot and UI-test launches start the same every time, so never show it there;
    /// `-bergr.announceLooks YES` shows it anyway (and again), to check its design.
    static var forced: Bool { UserDefaults.standard.bool(forKey: "bergr.announceLooks") }
    static var suppressed: Bool {
        if forced { return false }
        return UserDefaults.standard.bool(forKey: "bergr.demo")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Whether to show it: not yet shown, and the user already has machines. Without any, this is
    /// a fresh install on the empty first-run screen; it's marked as seen there instead, since a
    /// new user finds the themes in Settings.
    static func shouldShow(announced: Bool, hasMachines: Bool) -> Bool { !announced && hasMachines }

    /// Both of the look's terminal themes; the app follows through `ActiveLook`.
    static func use(_ look: AppLook) {
        if let light = look.lightTheme { UserDefaults.standard.set(light, forKey: TerminalTheme.lightKey) }
        if let dark = look.darkTheme { UserDefaults.standard.set(dark, forKey: TerminalTheme.darkKey) }
    }
}

/// Shows the themes sheet once.
struct LookAnnouncer: ViewModifier {
    @Environment(HostStore.self) private var hosts
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !LookAnnouncement.suppressed else { return }
                let defaults = UserDefaults.standard
                let announced = !LookAnnouncement.forced && defaults.bool(forKey: LookAnnouncement.key)
                // The Mac adds "This Mac" by itself on a fresh install: only machines the user added count.
                let added = hosts.hosts.contains { !$0.isLocal && !$0.isDemo }
                guard LookAnnouncement.forced || LookAnnouncement.shouldShow(announced: announced, hasMachines: added) else {
                    defaults.set(true, forKey: LookAnnouncement.key)
                    return
                }
                // After the main screen has settled, not over the launch.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                showing = true
            }
            .sheet(isPresented: $showing) {
                NewThemeSheet(look: LookAnnouncement.look) { showing = false }
                    // Marked once it is really on screen (another sheet can keep it from showing,
                    // and then it comes next launch); dismissing it any way counts.
                    .onAppear { UserDefaults.standard.set(true, forKey: LookAnnouncement.key) }
            }
    }
}

private struct NewThemeSheet: View {
    let look: AppLook
    let done: () -> Void
    @State private var useIcon = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("New theme: \(look.name)").font(.title2.bold())
                HStack(spacing: 12) {
                    if let light = look.light { LookPreview(style: light, title: "Light") }
                    if let dark = look.dark { LookPreview(style: dark, title: "Dark") }
                }
                Text("Restyles the chat and lists, and colors the terminal, in light and dark mode.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                #if os(iOS)
                if look.iconName != nil, UIApplication.shared.supportsAlternateIcons {
                    Toggle("Also use the \(look.name) icon", isOn: $useIcon)
                        .tint((look.light ?? look.dark)?.accent)
                }
                #endif
                Button {
                    LookAnnouncement.use(look)
                    #if os(iOS)
                    if useIcon, let icon = look.iconName { UIApplication.shared.setAlternateIconName(icon) }
                    #endif
                    done()
                } label: {
                    Text("Use \(look.name)").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint((look.light ?? look.dark)?.accent)
                Button("Not Now", action: done)
                    .frame(maxWidth: .infinity)
                    .tint((look.light ?? look.dark)?.accent)
                Text("Themes and the app icon are in Settings, under Appearance.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        #if os(iOS)
        // Tall enough for all of it: at half height the footer was cut off.
        .presentationDetents([.large])
        #else
        .frame(width: 440, height: 480)
        #endif
    }
}

/// A look at a glance: its gradient with a card, a reply bubble and an accent button.
private struct LookPreview: View {
    let style: LookStyle
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(style.secondary)
            RoundedRectangle(cornerRadius: 6).fill(style.card).frame(height: 16)
            HStack {
                Spacer()
                Capsule().fill(style.bubble).frame(width: 70, height: 16)
            }
            Capsule().fill(style.text.opacity(0.85)).frame(width: 90, height: 6)
            Capsule().fill(style.text.opacity(0.5)).frame(width: 60, height: 6)
            Spacer(minLength: 0)
            Capsule().fill(style.accent).frame(width: 46, height: 18)
                .overlay(Capsule().fill(style.onAccent).frame(width: 22, height: 4))
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(style.linearGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
        .accessibilityElement()
        .accessibilityLabel("\(title) preview")
    }
}
