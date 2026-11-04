---
name: app-store-screenshots
description: Make, check and update Hirte's App Store screenshots (iPhone 6.3" and iPhone Duo, captioned). Use when asked for App Store / marketing screenshots, when screens or the demo changed and the screenshots need redoing, or when changing screenshot captions, look or devices.
---

# App Store screenshots for Hirte

The screenshots show the built-in **demo machine** (HerdrKit `DemoCore`, content in
`HerdrKit/Sources/HerdrKit/DemoScript.swift`), so no real server, hostnames or keys ever appear.

## Make them

```sh
just screenshots                             # iPhone 17 Pro (6.3"), dark: the required set
just screenshots dark "iPhone Duo"           # iPhone Duo, outer display
just screenshots dark "iPhone 17 Pro Max"    # 6.9", if a 6.9" slot is ever needed
just screenshots light                # light mode
```

This runs `scripts/screenshots.sh`, which:

1. Uses a dedicated simulator per device, **"Hirte Screenshots (<device>)"**, and creates it if
   missing (so no personal data shows up) on the newest iOS runtime **that supports the device**:
   the iPhone Duo has its own runtime (`iOS-27-2-iPhone19-4`); the plain iOS 27.2 runtime fails with
   "Incompatible device".
2. Sets it to **en_US** (the status bar then reads `9:41`, not `09:41`; this needs one reboot the first
   time), the requested appearance, and Apple's marketing status bar: 9:41, full Wi-Fi and cell,
   **battery 100 % discharging** (`charged` shows a lightning bolt).
3. Uninstalls Hirte Dev, so the app starts empty and offers **Try the Demo**.
4. Runs the UI test `hirteUITests/DemoTourTests/testDemoTour` with `TEST_RUNNER_HIRTE_SHOTS`
   set. With that variable the test launches the app in English with a larger terminal font
   (`-terminal.fontSize`, from `TEST_RUNNER_HIRTE_SHOT_FONT`: **15 pt** on the 17 Pro, **17 pt** on the
   Pro Max, **14 pt** on the Duo, whose outer display is narrower; the default 13 pt leaves half of a big phone's screen empty)
   and writes `1-terminals`, `2-agent`, `3-needs-you`, `4-shell` and `5-tests` to
   `.build/screenshots/<device>/raw/`.
5. Frames shots 1–4 with ImageMagick: charcoal `#303438` background, title in SF Pro Display Bold
   (`#d9dad8`), subtitle in SF Pro Display Regular, the screenshot below with rounded corners. The
   layout was designed at 1320×2868 and scales with the capture's width; the screenshot's height fills
   what's left, so wider devices (the Duo) fit too. Output:
   `.build/screenshots/<device>/appstore/*.png`, at the capture's own size: **1206×2622** (17 Pro),
   **1320×2868** (17 Pro Max), **1398×2034** (Duo outer display).

It takes about 2 minutes. Run it outside the sandbox (simulator control needs it).

## Check them before handing over

Always look at the results; the test passing doesn't mean the pictures are good. Combine them into one
image and view it:

```sh
magick .build/screenshots/<device>/appstore/{1-terminals,2-agent,3-needs-you,4-shell}.png -resize x1000 +append /tmp/…/sheet.png
```

Check for:
- System popups over the app (e.g. iOS's one-time **"slide to type"** hint over the keyboard: the test
  taps its **Continue** button; add similar handling for any new popup).
- Status bar: `9:41`, no charging bolt, no carrier name.
- **Also run `just screenshots light` after UI changes** and look at the raw captures: the store set is
  dark, but people use light mode too (a dark title on the charcoal terminal once went unnoticed).
- Wrapped or clipped terminal lines (keep demo lines under ~44 columns; if a device wraps, lower its
  font in the `case` in `scripts/screenshots.sh`) and wrapped key bar labels.
- The terminal font is JetBrains Mono (bundled in `hirte/Fonts`); SF Mono there means it failed to load.
- Statuses: the demo changes them over the first minute (`DemoScript.timeline`), so a screen taken
  later shows later states. The list is shot first, ~2 s in.

## Change them

- **Captions and order**: the `shots`, `titles` and `subtitles` arrays at the top of
  `scripts/screenshots.sh`. Titles max ~24 characters, subtitles ~45, or they overflow at these sizes.
- **Which screens**: the UI test (`hirteUITests/hirteUITests.swift`): `open(app, "t3")` taps a terminal
  by its address, `shot(app, "name")` saves one. Add a name to `shots` to frame it.
- **What the screens show**: `DemoScript.swift` (terminals, screens, shell answers, timeline). Keep it
  generic: no real product names, people or companies.
- **Look**: colors, fonts and geometry in the framing loop at the end of `scripts/screenshots.sh`.

## Upload

App Store Connect → Hirte → **Vertrieb (Distribution)** → the version → **App-Vorschauen und
Bildschirmfotos** → **iPhone mit Dynamic Island (mittleres Display)** → drag in
`.build/screenshots/iphone-17-pro/appstore/*.png` in order (up to 10). Upload from `appstore/`, never
`raw/` (unframed, and it has an extra `5-tests.png`).

As of November 2026 this mid-size slot (6.1"/6.3") is the one App Store Connect requires, and it only
takes **1179×2556 or 1206×2622** (a 6.9" 1320×2868 file is rejected: "Die Dateiabmessungen sind
ungültig"). Third-party guides still say 6.9"; trust the sizes printed under the slot in App Store
Connect over any guide.
The **iPhone Duo** has its own optional slot (it adds an "optimized for iPhone Duo" badge). Apple
accepts the outer display (1398×2034) and the inner, unfolded display (2007×2853).

**The inner display can't be automated:** `simctl` and XCUITest have no fold control, and powering
off the outer display (`simctl io <device> screenConfig --display=<outer> power off`) leaves the inner
one black and crashes the simulator's SpringBoard. Don't try it again. If the simulator can be unfolded
by hand (Xcode's device window), the script works unchanged: the captures then have the inner size,
and the framing follows.

Outputs live in `.build/` (gitignored); they're regenerated, never committed.
