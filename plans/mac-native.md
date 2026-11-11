# Bergr for Mac: a native macOS app outside the Mac App Store

Status: plan, nothing implemented. Measured on 6643278 with Xcode 27 on Apple silicon.

Scope (decided): agent list across machines, chat, answer cards, notifications, settings, a menu-bar
status item (working / needs-you counts), and "Open in <terminal>" which launches the user's terminal
on `hc attach <address>` (locally) or `ssh … hc attach <address>` (remote machine). No embedded
terminal, no sandbox. Distribution: Developer ID + notarization, DMG on GitHub releases, Sparkle,
optional Homebrew cask. The iOS app stays on the App Store; both share code and `relay/`.

## 1. Measurement

### What was run

1. `xcodebuild -scheme bergr -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` **succeeds**,
   but it is not a native build: the destination resolves to "Designed for iPad" and the products land
   in `Debug-iphoneos`. It says nothing about macOS.
2. The same with `SDKROOT=macosx SUPPORTED_PLATFORMS=macosx MACOSX_DEPLOYMENT_TARGET=26.0` on the
   command line (no file touched) is a real macOS compile:
   - **HerdrKit and every dependency compile and link for macOS as is** (`HerdrKit`, `SSHTransport`,
     `KeyStore`, `TerminalCore`, Citadel, NIO; `Package.swift` already says `.macOS(.v15)`, and
     `ghostty-vt.xcframework` has a `macos-arm64_x86_64` slice). `ProcessTransport` (local
     `herdr-core connect`) already exists under `#if os(macOS)` in `HerdrKit/Sources/HerdrKit/Transport.swift`.
   - `BergrLiveActivity` fails (ActivityKit / Dynamic Island unavailable), `Shared/` fails in two files
     (`ActivityAttributes`, `LiveActivityIntent` "unavailable in macOS"), and the app target stops at
     module scanning: `Unable to resolve module dependency: 'UIKit'`.
3. To see past that stop, the app's own swiftc command was re-run as `-typecheck` on the 50 files that
   do not import UIKit/ActivityKit/CoreLocation/ReplayKit (13 files left out). Result: **215 errors in
   31 files, of which about 70 in 24 files are real platform differences**; the other ~145 are only
   "cannot find X" for types that live in the left-out files (`TerminalScreenModel` 23,
   `TerminalFont`/`Fonts` 14, `LiveActivityController` 10, `PushRegistration` 6, `KeepAlive` 6,
   `BergrActivityAttributes` 6, `ChatAttachment` 5). The compiler stops at the first error in a view
   body, so expect the real number to be somewhat higher (guess: 100 to 130 edits).

Nothing was changed in the repository; build products went to a scratch directory.

### iOS-only API usages per file (grep: `UI*` types, ActivityKit, CoreLocation, ReplayKit, PhotosUI, WidgetKit, iOS-only SwiftUI modifiers)

393 hits in 40 of 87 Swift files. By what happens to the file on the Mac:

| File | Lines | Hits | On the Mac |
|---|---:|---:|---|
| `bergr/Screen/TerminalCanvas.swift` | 1352 | 141 | not built (except `TerminalFont`/`Fonts`, to be moved out) |
| `bergr/Screen/ArrowStick.swift` | 185 | 16 | not built |
| `bergr/Screen/TerminalScreenView.swift` | 454 | 7 | not built (Mac gets its own chat window) |
| `bergr/Screen/TerminalPeek.swift` | 85 | 3 | not built |
| `bergr/Debug/ScreenRecording.swift` | 100 | 10 | not built |
| `bergr/Background/KeepAlive.swift` | 68 | 6 | not built |
| `bergr/Background/LiveActivityController.swift` | 291 | 7 | not built |
| `bergr/Background/LiveActivitySession.swift` | 267 | 6 | not built |
| `bergr/Background/AnswerIntent.swift` | 224 | 0 (6 compile errors) | not built in v1 |
| `Shared/BergrActivityAttributes.swift`, `Shared/AnswerPromptIntent.swift` | 107 | 3 | not built |
| `BergrLiveActivity/*` (3 files) | 342 | 4 | not built |
| `BergrNotificationService/NotificationService.swift` | 29 | 1 | only if APNs on Mac (see 2.8) |
| `bergr/Chat/ChatExtras.swift` | 347 | 33 (51 errors) | shared; zoomable image viewer (`UIScrollView`) gets a Mac twin |
| `bergr/Chat/ChatPreview.swift` | 245 | 15 | shared after `UIImage` → `PlatformImage` |
| `bergr/Chat/Attachments.swift` | 162 | 14 | Mac twin (NSOpenPanel, drop, paste) |
| `bergr/Chat/ComposerField.swift` | 111 | 12 | Mac twin (`UITextView` subclass today) |
| `bergr/Chat/ChatView.swift` | 2067 | 11 (30 errors) | shared with `#if os(iOS)` at a handful of sites |
| `bergr/Hosts/HostEditor.swift` | 393 | 10 | shared, small `#if` (keyboard modifiers, pasteboard) |
| `bergr/Chat/SelectTextSheet.swift` | 47 | 7 | not built (text is selectable on the Mac) |
| `bergr/Keys/KeysView.swift` | 280 | 6 | shared, pasteboard + toolbar placement |
| `bergr/Background/PushRegistration.swift` | 542 | 6 | split: relay/helper logic shared, `UIApplication`/`AppDelegate` part iOS |
| `bergr/Settings/TerminalTheme.swift` | 96 | 4 | shared; `Appearance.apply()` gets an `NSApp.appearance` branch |
| `bergr/RootView.swift` | 279 | 4 (12 errors) | iOS only; the Mac has `MacRootView` |
| `bergr/Hosts/MachinesView.swift` | 234 | 3 | shared, small `#if` |
| `bergr/Settings/SettingsView.swift` | 416 | 2 (16 errors) | shared sections; Mac wraps them in a `Settings` scene |
| `bergr/Screen/TerminalScreenModel.swift` | 408 | 1 | shared: only `import UIKit` to drop (chat needs this model) |
| 2 hits each: `TerminalListView`, `NewTerminalView`, `LicensesView`, `ChatUsage`, `ChatModels`, `AnswerCard`, `NewSessionView`, `AgentsView` | | 16 | shared; `navigationBarTitleDisplayMode`, `.topBarTrailing`, `UIPasteboard` |
| 1 hit each: `TerminalDetailView`, `SidebarView`, `SentImages`, `BergrApp` | | 4 | shared (`BergrApp` iOS only) |

Most frequent real errors: `navigationBarTitleDisplayMode` (9), `UIPasteboard` (9 outside the canvas,
20 in all), `UIImage` (12), `UIColor`/`systemBackground`/`systemGroupedBackground` (10),
`.topBarTrailing` (5), `textInputAutocapitalization`/`keyboardType` (5), `UIDevice` (3), `UIFont` (3),
`UIApplicationDelegateAdaptor` (1).

**Bottom line:** about 3,500 of the app's ~15,000 lines (terminal canvas, Live Activity, keep-alive,
widgets) are simply not part of the Mac app. The other ~80 % compiles after roughly 100 to 130 small
edits, plus four Mac replacements (composer, attachments, image viewer, app shell). The package layer
needs nothing.

## 2. Plan

### 2.1 Target setup

**A second app target, `bergrMac`, in the same project** (recommended), not one multiplatform target.
The two apps differ in almost every target-level thing: embedded extensions (Live Activity appex),
entitlements, Info.plist, signing identity (Developer ID vs App Store), Sparkle, deployment family.
One multiplatform target would need `[sdk=macosx*]` conditions and platform filters on the embed
phase; AGENTS.md already notes conditional keys only work at project level in this project format.

`bergr.xcodeproj/project.xcproj` additions:
- product `<PRODUCTS>/Bergr.app` (target name `bergrMac`, `PRODUCT_NAME` = `Bergr$(BERGR_NAME_SUFFIX)`),
- target settings: `SDKROOT=macosx`, `SUPPORTED_PLATFORMS=macosx`, `MACOSX_DEPLOYMENT_TARGET=26.0`
  (iOS is 26.0 and the views use 26 APIs), `ENABLE_HARDENED_RUNTIME=YES`,
  `CODE_SIGN_ENTITLEMENTS=Config/bergrMac.entitlements`, `INFOPLIST_FILE=Config/Mac-Info.plist`,
  `PRODUCT_BUNDLE_IDENTIFIER=$(BERGR_BUNDLE_ID_PREFIX).bergr.mac$(BERGR_BUNDLE_ID_SUFFIX)`, the same
  `SWIFT_*` settings as `bergr` (MainActor default isolation, approachable concurrency),
  `CURRENT_PROJECT_VERSION`/`MARKETING_VERSION` equal to the other targets (`just archive` fails when
  targets disagree on the build number, so the Mac target shares it; Sparkle only needs it to grow),
- package products: `HerdrKit`, plus remote package Sparkle 2 (Mac target only),
- a shared scheme `bergrMac`,
- folder memberships (next section).

**Bundle id: a separate one, `<prefix>.bergr.mac`** (`com.redacted.bergr.mac`, Debug `.mac.dev`).
The iOS app is installable on Apple silicon Macs under `com.redacted.bergr` ("Designed for iPad",
what `just mac` installs today); the same id would make the two collide in LaunchServices, defaults,
keychain and notification settings. A separate id also gives the relay a distinct APNs topic, and
Developer ID needs its own App ID and profile anyway.

### 2.2 Which files are shared, and how they are split

Folders are synchronized, so the split is by folder and needs no per-file project edits:

| Folder | Targets | Content |
|---|---|---|
| `bergr/` | `bergr`, `bergrMac` | everything shared (models, sessions, chat, agents list, settings sections) |
| `bergrIOS/` (new) | `bergr` | files moved with `git mv`: `Screen/TerminalCanvas`, `ArrowStick`, `TerminalScreenView`, `TerminalPeek`, `Background/KeepAlive`, `LiveActivityController`, `LiveActivitySession`, `AnswerIntent`, `Debug/ScreenRecording`, `Chat/ComposerField`, `Attachments`, `SelectTextSheet`, `BergrApp`, `RootView`, the `AppDelegate` half of `PushRegistration` |
| `bergrMac/` (new) | `bergrMac` | Mac app shell, Mac twins with the **same type names** (`ComposerField`, `AttachmentPicker`…), terminal launcher UI, updater |
| `Shared/` | as today | `BergrActivityAttributes.swift` and `AnswerPromptIntent.swift` move to `SharedIOS/` (or get `#if os(iOS)` around the whole file); `AgentsSnapshot` and `PushAlertKey` stay and are added to `bergrMac` |

Rule: a whole file that is one platform's goes into that platform's folder (the compiler then enforces
the split); `#if os(iOS)` only for single modifiers or a few lines inside shared views. To keep the
`#if`s out of view bodies, a shared `bergr/Platform.swift` holds:
- `typealias PlatformImage = UIImage | NSImage`, `Image(platformImage:)`, JPEG/PNG data helpers,
- `Pasteboard.copy(_ string:)`, `.string`, `.hasImage`, `.image` (replaces 12 `UIPasteboard` sites outside the canvas),
- `Color.systemBackground` / `.groupedBackground` shims,
- `View.inlineNavigationTitle()`, `.noAutocapitalization()`, `.urlKeyboard()`, `ToolbarItemPlacement.trailingAction`
  (no-ops or `.primaryAction` on the Mac),
- `DeviceName.current` (`UIDevice.current.name` / `Host.current().localizedName`).

To move out of iOS-only files because shared code needs them: `TerminalFont` and `Fonts` (from
`TerminalCanvas.swift`, `UIFont` → `CTFont`), `ChatAttachment` (model part of `Attachments.swift`),
`LiveActivityController.target(of:)` (URL parsing, used by routing), and the relay/helper part of
`PushRegistration` (see 2.8). `TerminalScreenModel` stays shared (chat sends through it); it only
loses `import UIKit`. `SessionStore` is created in `RootView` today; the Mac creates it in the `App`
so windows and the menu bar share it.

### 2.3 Mac replacements

| iOS | Mac |
|---|---|
| `BergrApp` + `RootView` (split view, compact columns, "beside" pane) | `BergrMacApp`: `WindowGroup("Bergr", id: "main") { MacRootView }` (sidebar: machines and agents, detail: chat), `WindowGroup(for: AgentRef.self) { ChatWindow }` with `AgentRef { host: UUID, address: String }` (Codable, Hashable: one window per agent, reopening focuses it, state restoration for free), `Settings { MacSettings }`, `MenuBarExtra` |
| `UIApplicationDelegateAdaptor` | `NSApplicationDelegateAdaptor`: `applicationShouldTerminateAfterLastWindowClosed` = false (the menu-bar item keeps it alive), reopen handler, APNs callbacks if enabled |
| toolbar buttons, `agentShortcuts` background view | `.commands { }`: New Session ⌘N, New Window for Agent ⌥⌘N, Open in Terminal ⌘T (or ⇧⌘O), Next/Previous agent needing you ⌘] / ⌘[, Find, Reply focus ⌘L, Interrupt ⌘. , Settings ⌘, (free with `Settings`), Check for Updates… |
| `ComposerField` (`UITextView`) | `NSTextView`-backed composer: Return sends, ⇧Return newline, paste and drop of images/files |
| `Attachments` (PhotosPicker, camera, pasteboard) | `fileImporter`/`NSOpenPanel`, drag and drop, paste, screenshot from clipboard |
| `LayoutScrollView` zoom viewer in `ChatExtras` | Quick Look (`.quickLookPreview`) or a magnifiable `ScrollView` |
| `SelectTextSheet` | none: `.textSelection(.enabled)` |
| `UIPasteboard` | `NSPasteboard` behind `Pasteboard` |
| `Appearance.apply()` on `UIWindowScene` windows | `NSApp.appearance = …` |
| Live Activity, Dynamic Island, widgets | `MenuBarExtra`: icon plus counts ("2 · 1!"), `.menuBarExtraStyle(.window)` popover listing agents that need you / are working, click opens the agent's window; counts come from the same reduction the Live Activity uses (`AgentsSnapshot`, once cut loose from `BergrActivityAttributes`) |
| `KeepAlive` (CoreLocation), background tasks | none: the process stays alive and keeps its SSH connections; reconnect on wake via `NSWorkspace.didWakeNotification` |
| `AgentNotifier` local notifications | same code: `UNUserNotificationCenter` works unchanged on macOS (needs a signed app with a bundle id); clicking opens the agent window through `NotificationRouter` → `openWindow(value: AgentRef)` |
| Answering from the Live Activity (`AnswerIntent`) | v1: answer cards in the chat only. Later: `UNNotificationAction`s on the alert |
| Haptics, `sensoryFeedback` | compile as is (no effect) |

### 2.4 SSH keys on the Mac

- **Secure Enclave stays the default.** It works on Apple silicon (and T2 Intel) Macs. Two Mac
  specifics in `KeyStore`: (a) it uses the data protection keychain (`kSecUseDataProtectionKeychain`),
  which on macOS needs the `keychain-access-groups` entitlement and therefore a **provisioning profile
  embedded in the Developer ID build**; an unsigned or ad-hoc build (CI, contributors) gets
  `errSecMissingEntitlement` and must show "keys unavailable in this build" instead of crashing;
  (b) Macs without Touch ID (mini, Studio, clamshell) need `.userPresence` rather than a
  biometry-only flag, so the login password or Apple Watch can unlock.
- **Also offer "Import from ~/.ssh"** (recommended, cheap): `OpenSSHImport` already parses OpenSSH
  private keys; on the Mac the picker opens at `~/.ssh` (no sandbox, no bookmark needed). Imported keys
  are stored like on iOS.
- **Not in v1: ssh-agent** (`SSH_AUTH_SOCK`; would cover 1Password, Secretive, YubiKeys). It needs an
  agent-protocol client and a custom NIOSSH key type. Worth a follow-up.
- Optional nicety: "Add from ~/.ssh/config" lists `Host` entries to prefill a machine (name, user, port).
- Consequence to know: "Open in terminal" runs the system `ssh`, which cannot use Bergr's Secure
  Enclave key. The user needs their own working `ssh <host>` (own key or agent). The settings pane
  should say so and offer "Copy public key / authorized_keys line" plus a "Test" button. See decision 6.

### 2.5 "This Mac" as a machine

`hc attach <address>` "locally" implies a machine without SSH. `Host` gets `local: Bool?` (optional,
like `demo`, so saved hosts still decode); its connector uses the existing `ProcessTransport` to run
`herdr-core connect` (found on `PATH` or `~/.local/bin`, as the SSH wrapper does), with
`HostConnection.ssh == nil` (already allowed for the demo). `exec`/`openExec`/`uploadImage` need a
`Process`-based path for local hosts (upload is a file copy). Offered automatically on first launch
when `herdr-core` is found.

### 2.6 Terminal launcher

Pure part (testable, in `HerdrKit` under `#if os(macOS)` or plain Swift so `swift test` covers it):

```swift
enum TerminalApp: String, CaseIterable { case ghostty, iterm2, terminal, wezterm, kitty
    var bundleID: String }            // below
struct AttachCommand { static func argv(host: Host?, target: SSHTarget?, address: String) -> [String] }
struct LaunchPlan { let executable: URL; let arguments: [String]; let script: String? }
```

- Local: `["hc", "attach", address]`, run through a login shell so `PATH` has `~/.local/bin`:
  `/bin/zsh -lc 'exec hc attach t7'` (or the absolute path found at detection time).
- Remote: `["ssh", "-t", "-p", "<port>", "<user>@<host>", "PATH=\"$HOME/.local/bin:$PATH\" hc attach <address>"]`.
  `-t` is required (attach needs a tty). `-p` only when not 22.
- `address` is validated against `^[A-Za-z0-9._/-]+$` (covers `t7`, names, `machine/t7`) and user/host
  are single-quoted; anything else is refused. This is the test surface: quoting, port, federated
  addresses, refusal of metacharacters.

Detection: `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` per terminal (no sandbox, no
`LSApplicationQueriesSchemes`). Default selection: first installed in the order below; Terminal.app is
always there.

| Terminal | Bundle id | Launch |
|---|---|---|
| Ghostty | `com.mitchellh.ghostty` | `open -na <Ghostty.app> --args -e <script>` (new instance per attach). If the installed version has the AppleScript dictionary (newer releases), prefer "new window with command" in the running instance. **Verify on this Mac (Ghostty is installed).** |
| iTerm2 | `com.googlecode.iterm2` | open a generated `.command` file with iTerm (`NSWorkspace.open([file], withApplicationAt:)`); alternative AppleScript `create window with default profile command "<cmd>"` |
| Terminal.app | `com.apple.Terminal` | open a generated `.command` file with Terminal (no Automation prompt). Alternative AppleScript `do script "<cmd>"` needs `NSAppleEventsUsageDescription`, the `com.apple.security.automation.apple-events` entitlement and a one-time consent |
| WezTerm | `com.github.wez.wezterm` | `<WezTerm.app>/Contents/MacOS/wezterm start -- <argv…>` |
| Kitty | `net.kovidgoyal.kitty` | `<kitty.app>/Contents/MacOS/kitty --single-instance -- <argv…>` |

The generated script is `~/Library/Caches/<bundle id>/attach/<uuid>.command`, mode 0700, content
`#!/bin/zsh -l` + `exec <quoted argv>`; old ones are removed at launch. Using the script for every
terminal (pass its path as the single program argument) keeps quoting in one place; then only the
"how do I start program X in terminal Y" line differs per terminal. The `.command` route is preferred
over AppleScript: no TCC prompt, no extra entitlement.

UI: Settings → "Terminal" picker (installed ones only), toolbar button and context-menu item
"Open in Ghostty" on agent rows and chat windows, `Commands` entry. Failure (ssh not set up, `hc`
missing) is visible in the terminal itself; Bergr only reports launch failures.

### 2.7 Signing, notarization, DMG, Sparkle, Homebrew: `just mac-release`

One-time, by the user (cannot be automated):
1. App ID `com.redacted.bergr.mac` with Keychain Sharing (and Push Notifications if 2.8 option B).
2. A "Developer ID Application" certificate (or cloud-managed Developer ID signing, which needs the
   Account Holder or a specifically permitted Admin on the API key) and a Developer ID provisioning
   profile for that App ID.
3. Sparkle EdDSA key: `generate_keys` (private key in the login keychain; export a copy into sops next
   to the App Store Connect key), public key into `Config/Mac-Info.plist` as `SUPublicEDKey`.
4. Optional: a tap repository `homebrew-bergr` (or `homebrew-tap`).

`Config/bergrMac.entitlements`: no `com.apple.security.app-sandbox`; `keychain-access-groups` =
`$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`; `com.apple.developer.aps-environment` only with
2.8 B; no Apple Events entitlement while the `.command` route is used.

`Config/Mac-Info.plist`: `SUFeedURL` = `https://github.com/<owner>/bergr/releases/latest/download/appcast.xml`,
`SUPublicEDKey`, `SUEnableAutomaticChecks`, `LSApplicationCategoryType` = developer-tools,
`NSLocalNetworkUsageDescription`, `LSMinimumSystemVersion`.

Recipe (new `scripts/mac-release.sh`, called by `just mac-release [upload]`; reuses the App Store
Connect key handling of `just archive`):
```
xcodebuild -project bergr.xcodeproj -scheme bergrMac -configuration Release \
  -archivePath .build/mac/Bergr.xcarchive -allowProvisioningUpdates <auth> <signing> archive
xcodebuild -exportArchive -archivePath .build/mac/Bergr.xcarchive \
  -exportOptionsPlist Config/MacExportOptions.plist -exportPath .build/mac/export <auth>   # method: developer-id
codesign --verify --deep --strict .build/mac/export/Bergr.app
hdiutil create -volname Bergr -srcfolder <staging with Bergr.app + /Applications symlink> -ov -format UDZO Bergr-<version>.dmg
codesign --sign "Developer ID Application: …" --timestamp Bergr-<version>.dmg
xcrun notarytool submit Bergr-<version>.dmg --key <p8> --key-id <id> --issuer <issuer> --wait
xcrun stapler staple Bergr-<version>.dmg && spctl -a -t open --context context:primary-signature -v Bergr-<version>.dmg
<Sparkle>/bin/generate_appcast --ed-key-file <key> --download-url-prefix https://github.com/<owner>/bergr/releases/download/mac-v<version>/ .build/mac/dist
gh release create mac-v<version> Bergr-<version>.dmg appcast.xml --notes-file …      # only with `upload`
```
One artifact (the notarized DMG) serves people, Sparkle and Homebrew. Tags are `mac-v<version>` so
they do not mix with iOS builds; the appcast is re-uploaded to each release so `latest/download` works.
Sparkle 2 comes in through SwiftPM, wired as `SPUStandardUpdaterController` + a "Check for Updates…"
command; without a sandbox it needs no XPC service configuration. `just licenses` must gain a Sparkle
entry (it fails when a package has no license).

Homebrew cask (`Casks/bergr.rb` in the tap; `just mac-release` prints the new `version`/`sha256`):
```ruby
cask "bergr" do
  version "0.3.0"
  sha256 "…"
  url "https://github.com/<owner>/bergr/releases/download/mac-v#{version}/Bergr-#{version}.dmg"
  name "Bergr"
  desc "Watch and answer coding agents running under herdr"
  homepage "https://github.com/<owner>/bergr"
  auto_updates true
  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64
  app "Bergr.app"
  zap trash: ["~/Library/Preferences/com.redacted.bergr.mac.plist", "~/Library/Caches/com.redacted.bergr.mac"]
end
```

Other justfile recipes: `just mac-native [configuration]` (build and open; the existing `just mac`
stays as the iPad build until the native app replaces it), `just mac-build` (unsigned compile check).

### 2.8 Notifications and the relay

**A (recommended for v1): local notifications only.** A running Mac app holds its SSH connections and
`AgentNotifier` already raises `UNUserNotificationCenter` alerts from the live event stream; with the
menu-bar item the app normally stays running. No APNs, no notification extension, no relay
registration from the Mac. The phone keeps getting pushes as today.

**B (later, if alerts are wanted while Bergr is quit): APNs.** It works for a Developer ID app:
- needs `com.apple.developer.aps-environment` (restricted: provisioning profile required, same one as
  for the keychain), `NSApplication.registerForRemoteNotifications()`, token in
  `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`;
- environment: Developer ID / Release builds are **production**, Xcode development builds are
  **sandbox**; `PushRegistration.sandbox` must derive it on the Mac from
  `Contents/embedded.provisionprofile` (not `embedded.mobileprovision`);
- **relay code: no change needed.** `relay/src/index.js` sends `apns-topic: reg.bundle_id` with the
  team's token-auth key, and an APNs `.p8` key covers every app of the team, macOS included. Only
  configuration: if the `ALLOWED_BUNDLE_IDS` variable is set, add `com.redacted.bergr.mac` and
  `.mac.dev`. The Live Activity routes (`/v1/activity*`) are simply never called by the Mac;
- the encrypted alert text (`e`, decrypted by `BergrNotificationService`) needs a **macOS notification
  service extension**. App extensions on macOS must be sandboxed, so the extension and the unsandboxed
  app have to share `PushAlertKey` through an app group (macOS groups: `group.` ids with a profile on
  macOS 15+, or `<TeamID>.` prefix). Without the extension the Mac shows the relay's generic
  placeholder text. This is the expensive part of B;
- helper side (`bergr-notify.py` on the machines): a Mac is one more registered device; check that it
  does not alert twice when the app is also connected (the Mac would suppress its local alert or the
  push, as iOS does in the foreground).

### 2.9 CI

`.github/workflows/ci.yml` is switched off (`if: false`) until runners have Xcode 27. When it runs:
add `xcodebuild -scheme bergrMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build`
after the iOS build (same Ghostty cache, +3 to 5 minutes) and let `swift test` cover the launcher tests
(they live in HerdrKit). The unsigned Mac build must start without the keychain entitlement (2.4).
Releases stay local (`just mac-release`), like `just archive`; no signing secrets in CI.

## 3. Chunks

Chunk 0 is serial and lands first; A to F then run in parallel, one agent and worktree each, with
disjoint files. Estimates are agent working time including build/test loops, not review.

### 0. Foundation: both targets compile (4 to 6 h)

Owns: `bergr.xcodeproj/project.xcproj`, `Config/Mac-Info.plist`, `Config/bergrMac.entitlements`, the
`git mv`s into `bergrIOS/` and `SharedIOS/`, `bergr/Platform.swift`, extraction of `TerminalFont`/
`Fonts`/`ChatAttachment`/URL-target parsing, every `#if os(iOS)` edit in shared views, and **stubs** in
`bergrMac/` for everything the later chunks fill in (`BergrMacApp` with one plain window showing the
agents list and chat, `ComposerField` as a plain `TextField`, empty `AttachmentPicker`, `Updater`,
`TerminalLauncher.open` that only logs). Also adds the Sparkle package and the `bergrMac` scheme so no
later chunk edits the project file.
Tests: existing ones unchanged. Add `bergrTests` cases for `Pasteboard`-free logic moved out
(`TerminalFont` keys, URL target parsing) if they had none.
Done when: `just build` and `just test` pass as before, the iOS app looks unchanged on a phone
(screenshots UI test, light and dark), and
`xcodebuild -scheme bergrMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` succeeds and
the app launches, connects to a machine and shows a chat.

### A. Mac shell: windows, commands, menu bar (3 to 4 h)

Owns: `bergrMac/App/*` (`BergrMacApp`, `MacRootView`, `ChatWindow`, `MacCommands`, app delegate),
`bergrMac/MenuBar/*`, `bergrMac/Settings/MacSettings.swift` (tabs hosting the shared sections).
Contract from 0: `AgentRef`, app-scoped `SessionStore`, `AgentCounts` (working / needs-you) as a pure
function over sessions.
Tests: `AgentCounts` reduction (pure; in `bergrTests` if it lives in `bergr/`, which it should, since
the Live Activity can use the same).
Done when: one window per agent (reopening focuses), state restores after relaunch, the menu-bar item
shows live counts and opens the right window, closing all windows keeps the app running, every command
has a working shortcut. Checked visually in light and dark.

### B. Terminal launcher (2 to 3 h)

Owns: `HerdrKit/Sources/HerdrKit/TerminalLaunch.swift` (pure: `TerminalApp`, `AttachCommand`,
`LaunchPlan`), `HerdrKit/Tests/HerdrKitTests/TerminalLaunchTests.swift`, `bergrMac/Terminal/*`
(detection, script file, `NSWorkspace`/`Process` launch, settings picker view, "Open in …" button).
Tests: argv for local and remote, port handling, federated address, quoting, refusal of unsafe
addresses, the launch plan per terminal.
Done when: `swift test` passes and, on this Mac, Ghostty and Terminal.app open attached to a local and
to a remote agent (Ghostty verified by hand; iTerm2, WezTerm, Kitty by plan tests unless installed).

### C. Chat on the Mac: composer, attachments, images (3 to 4 h)

Owns: `bergrMac/Chat/*` (`ComposerField`, `AttachmentPicker`, image viewer) and nothing in `bergr/`
(any shared-file need goes back to the lead as a contract change).
Tests: attachment conversion (file/pasteboard image → `ChatAttachment` JPEG) as unit tests where it is
pure.
Done when: Return sends and ⇧Return breaks the line, IME input works, paste and drop of an image
attach it and it arrives on the machine, answer cards work with keyboard and mouse, text in messages
is selectable and copyable.

### D. Keys and "This Mac" (3 to 4 h)

Owns: `HerdrKit/Sources/KeyStore/*`, `HerdrKit/Tests/KeyStoreTests/*`, `bergr/Keys/*`,
`bergr/Hosts/*`, `bergr/Terminals/ConnectionAttempt.swift`, `bergr/Terminals/HostSession+Command.swift`,
`HostSession+Upload.swift`.
Work: `.userPresence` on the Mac, a clear "no keychain entitlement" state, import from `~/.ssh`,
`Host.local` with `ProcessTransport`, local exec and upload, first-launch offer of "This Mac".
Tests: `Host` decoding with and without `local`, local connector against a fake executable
(`ProcessTransport` is already used in tests), KeyStore error mapping.
Done when: a signed build creates and uses a Secure Enclave key, an imported `~/.ssh/id_ed25519`
connects, "This Mac" lists local agents and a reply reaches one, an unsigned build starts and explains
why keys are unavailable. iOS behaviour unchanged (`just test`, iOS build).

### E. Notifications (1 to 2 h for option A; +4 to 6 h for option B)

Owns: `bergr/Background/AgentNotifier.swift`, `NotificationRouter.swift`, `Delivery.swift`,
`PushRegistration.swift`, `bergrMac/Notifications/*`; with option B also a new
`BergrMacNotificationService/` and its target (then E takes the project file after 0, and F must not
touch it).
Done when (A): an agent that needs you or finishes raises an alert while its window is not key,
clicking opens that agent's window, alerts respect the per-agent quiet setting and Focus. (B): a push
arrives with Bergr quit, with decrypted text, in both sandbox and production.

### F. Release (2 to 3 h, plus the user's one-time steps in 2.7)

Owns: `justfile`, `scripts/mac-release.sh`, `Config/MacExportOptions.plist`, `bergrMac/Updates/*`
(Sparkle wiring), `.github/workflows/ci.yml`, `README.md`, `AGENTS.md`, `bergr/Licenses/licenses.json`
(via `just licenses`), the cask file.
Tests: `scripts/mac-release.sh --dry-run` prints the steps and checks prerequisites (certificate,
profile, keys) before the long build, like `just archive`.
Done when: `just mac-release` yields a stapled DMG that passes `spctl` on a second Mac account or
machine, an older installed build updates itself through Sparkle from a test appcast, and
`brew install --cask` from the tap installs it.

Order and total: 0 (4 to 6 h), then A to F in parallel (longest 3 to 4 h), then an integration pass
with visual checks (2 to 3 h). About two working days end to end; roughly 20 to 26 agent hours.

Likely friction: chunk 0 touches many view files, so it should land while iOS work on those files is
paused; C may find that `ChatView` needs more seams than 0 provided.

## 4. Decisions for the user

1. **Bundle id**: separate `com.redacted.bergr.mac` (recommended) or the iOS id. And: once the native
   app ships, switch off "available on Mac" for the iOS app in App Store Connect?
2. **Target**: second target `bergrMac` with `bergrIOS/` and `bergrMac/` folders (recommended, moves
   about 14 files) or `#if os(iOS)` around whole files in place (no moves, noisier files).
3. **Push on the Mac**: local notifications only in v1 (recommended) or APNs too (needs a sandboxed
   notification extension, app group, +4 to 6 h; relay needs only `ALLOWED_BUNDLE_IDS`, if set).
4. **Keys**: Secure Enclave default plus import from `~/.ssh` (recommended); ssh-agent support later
   or now?
5. **"This Mac" local machine** without SSH (via `ProcessTransport`) in v1? Recommended; "hc attach
   locally" has no meaning without it.
6. **Terminal attach uses the system `ssh`**, so it cannot use a Secure Enclave key held by Bergr.
   Accept (document, offer "copy public key" and a test button), or plan a Bergr ssh-agent later?
7. **Launch method**: generated `.command` script (no permission prompt; recommended) or AppleScript
   for Terminal/iTerm (nicer tab control, one-time Automation consent, extra entitlement).
8. **Minimum macOS**: 26 (matches iOS 26 APIs; recommended) or lower with availability checks.
   **Architecture**: Apple silicon only (recommended; Secure Enclave, less testing) or universal.
9. **Versioning**: Mac shares `MARKETING_VERSION` and build number with iOS (recommended, keeps
   `just archive`'s check simple) or its own version line; release tags `mac-v<version>`.
10. **Where releases live**: this GitHub repository's releases (must be public for Sparkle and
    Homebrew) and a tap named `homebrew-bergr`? Who holds the Developer ID certificate (cloud-managed
    signing needs the Account Holder's permission on the API key)?
11. **Dock**: normal app with Dock icon plus menu-bar item (recommended), or a setting for
    menu-bar-only (`LSUIElement`)?
12. **`just mac`**: keep the iPad build beside `just mac-native` for now, or replace it as soon as the
    native app is usable (memory note says app changes are installed on phone and this Mac).

## Decisions (user, 2026-11-10)

All recommendations accepted: separate bundle id `com.redacted.bergr.mac`; second target with
`bergrIOS/` and `bergrMac/` folders beside shared `bergr/`; local notifications only in v1; Secure
Enclave keys plus import from `~/.ssh` (ssh-agent later); a "This Mac" machine in v1; terminal attach
uses the system `ssh` (document it, add copy-public-key and test buttons); launch through a generated
`.command` script; macOS 26, Apple silicon only; shared MARKETING_VERSION/build number with tags
`mac-v<version>`; this repo's GitHub releases, tap `MaroonBrian1928/homebrew-tap`, Developer ID cert via
the API key; Dock icon plus menu-bar item; keep `just mac` (iPad build) and add `just mac-native`.
