# Notes for coding agents

Hirte is an iPhone client for herdr-core: SSH to a machine, run `herdr-core connect` there, and speak
its framed JSON-RPC protocol to list, attach to and manage terminals. See `README.md` for what it does
and how to build it.

## Layout

- `hirte/`: the app. SwiftUI for screens; the terminal itself is UIKit (`Screen/TerminalCanvas.swift`
  draws cells, handles touch, keys and pinch). `Terminals/HostSession.swift` owns one machine's
  connection and keeps a live snapshot from `events.subscribe`.
- `HerdrKit/` (Swift package, Swift 6 strict concurrency):
  - `HerdrKit`: protocol client (`HerdrClient` over any `ByteTransport`), models, events, grouping by
    herdr-app spaces, and `DemoCore`, an in-app fake herdr-core behind the same transport (content in
    `DemoScript.swift`)
  - `SSHTransport` (Citadel), `KeyStore` (Secure Enclave keys), `TerminalCore` (libghostty-vt wrapper)
- `vendor/ghostty`: submodule; `just ghostty` builds `HerdrKit/Frameworks/ghostty-vt.xcframework`
  (not checked in). Its C headers are the reference for the terminal API.

## Commands

`just build` (compiles for a device), `just test` (HerdrKit tests), `just sim`, `just phone [name]`,
`just screenshots`, `just video` (simulator), `just video-device` (the unfolded Duo, over Wi-Fi),
`just archive [true]`. Simulator and device work needs to run outside the sandbox.
App tests: `xcodebuild … -only-testing:hirteTests test` (unit) or `-only-testing:hirteUITests test`
(UI) on a simulator.

## Conventions and pitfalls

- **Two apps.** Debug builds are "Hirte Dev" (`com.pavelzw.hirte.dev`, amber icon), Release is
  "Hirte" (`com.pavelzw.hirte`). They differ through project-level `HIRTE_*_SUFFIX` settings.
- **Signing**: `DEVELOPMENT_TEAM` and `HIRTE_BUNDLE_ID_PREFIX` are set once, at project level (not
  per target). The justfile and `scripts/screenshots.sh` pass `HIRTE_TEAM` / `HIRTE_BUNDLE_ID_PREFIX`
  from the environment over them, so others build with their own team without editing tracked files.
  (The new project format has no way to reference an `.xcconfig`, as far as we know.)
- **CI** (`.github/workflows/ci.yml`): HerdrKit tests (without `KeyStoreTests`, which need the data
  protection keychain) and an unsigned device build, on a macOS runner with Xcode 27.
- **The project file** is `hirte.xcodeproj/project.xcproj` (a JSON-like format, not `project.pbxproj`).
  Per-configuration keys (`KEY[config=Debug]`) only work in the project-level `build-settings`, not in
  a target's. `hirte/` is a synchronized folder: new files there are in the target automatically.
- **Build numbers**: `CURRENT_PROJECT_VERSION`, 1, 2, 3… per `MARKETING_VERSION`. A successful
  `just archive true` raises it; commit that.
- **Generated files**: `hirte/Licenses/licenses.json` (`just licenses`, after changing Swift packages,
  bundled fonts or the Ghostty pin; it fails if a package has no license entry),
  `hirte/Settings/themes.json` (`just themes`), the app icons (`just icon` from `assets/logo.svg`).
- **Bundled fonts** live in `hirte/Fonts` and are registered at runtime (`Fonts.mono`); each needs a
  license entry.
- **Terminal colors** come from the selected theme (`TerminalTheme`), set as libghostty-vt's default
  colors and palette. The terminal screen's title bar, keyboard and overlays follow the theme's
  brightness, not the app's appearance; the app appearance is set on the window
  (`Appearance.apply()`), not with `.preferredColorScheme`.
- **Check UI changes visually**, in light and dark, on a narrow phone and the iPhone Duo: run a UI
  test that saves screenshots (`TEST_RUNNER_HIRTE_SHOTS=<folder>`) and look at them. Rows carry their
  terminal address as accessibility identifier; the terminal is the element `terminal-screen`.
- **App Store screenshots**: see `.claude/skills/app-store-screenshots`.
- **Videos**: `testVideoTour` (simulator) and `testDeviceVideoTour` (device) are the scripts; they
  skip unless `HIRTE_VIDEO` / `HIRTE_DEVICE_VIDEO` is set. On a device the app records itself
  (`hirte/Debug/ScreenRecording.swift`, ReplayKit): lower resolution than a screen recording, and
  without the system keyboard. Debug-only launch arguments: `-hirte.demo YES` opens the demo machine,
  `-hirte.record <name>` records into `Documents/<name>.mp4`.
- **Uploads** (`just archive true`) authenticate with an App Store Connect API key: from
  `.appstoreconnect.sops.yaml` (sops-encrypted, not committed: `key_id`, `issuer_id`, `private_key`),
  decrypted into a temporary file for the run; `just archive` stops right away if it can't read it.
  The key needs the Admin role: exporting uses Apple's cloud-managed distribution certificate.
- **`just archive`** puts `/usr/bin` first on `PATH`: Xcode's openrsync fails ("Copy failed") when a
  newer `rsync` from pixi or Homebrew comes first.
- **Demo content** stays generic (no real product names, people or companies) and keeps lines under
  about 44 columns.
- **Workarounds for herdr-core bugs** say so in a comment (what the core does, the version it was
  seen in), so they can be removed once it's fixed upstream.
- Commit messages: a short imperative subject, then what changed and why.
