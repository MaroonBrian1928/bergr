---
name: app-store-screenshots
description: Make, check and update Bergr's App Store screenshots (iPhone 6.3" and iPhone Duo, captioned, from the demo; `just appstore-shots`). Use when asked for App Store / marketing screenshots, when screens or the demo changed and the screenshots need redoing, or when changing screenshot captions, look or devices.
---

# App Store screenshots for Bergr

The screenshots show the built-in **demo machine** (HerdrKit `DemoCore`, content in
`HerdrKit/Sources/HerdrKit/DemoScript.swift`), so no real server, hostnames or keys ever appear.

## Make them

```sh
just appstore-shots                             # iPhone 17 Pro (6.3"), dark: the required set
just appstore-shots light                       # light mode (look at it after UI changes)
just appstore-shots dark "iPhone Duo"           # iPhone Duo, outer display
just appstore-shots dark "iPhone 17 Pro Max"    # 6.9", if a 6.9" slot is ever needed
```

(`just screenshots` is the same, under its old name.) Source `.envrc.local` first for signing.
This runs `scripts/screenshots.sh`, which:

1. Uses a dedicated simulator per device, **"Bergr Screenshots (<device>)"** (created if missing, on
   the newest runtime that supports the device; the Duo has its own runtime), set to en_US with
   Apple's marketing status bar (9:41, full signal, battery 100 % discharging). See `scripts/simulator.sh`.
2. Runs `bergrUITests/DemoShotsTests` (the new demo: three machines, five agents, `-bergr.demo YES`)
   with `TEST_RUNNER_BERGR_SHOTS` and `TEST_RUNNER_BERGR_SHOT_APPEARANCE`; frames land in `raw/`.
   One retry if a tap flakes.
3. Draws the Lock Screen (Live Activity) and Home Screen (widgets) frames with
   `scripts/widget-render/render.sh` from the real `BergrLiveActivity/` views: the simulator can't
   show a Live Activity or widgets from the demo. They're drawn at iPhone 17 Pro geometry.
4. Frames shotlist frames 1 to 8 (`plans/screenshot-shotlist.md`) with ImageMagick: charcoal
   `#303438`, caption in SF Pro Display Bold, subcaption in Regular (both shrink to fit 90 % of the
   width), the screenshot below with rounded corners. Output:
   `.build/screenshots/<device>-<appearance>/appstore/{1-agents,2-summaries,3-answer,4-risky,5-lock-screen,6-usage,7-reply,8-widgets}.png`
   at the capture's own size: **1206×2622** (17 Pro), **1320×2868** (Pro Max), **1398×2034** (Duo).

The store set is dark. It takes several minutes (a full build plus the shot test). Run it outside
the sandbox (simulator control needs it).

## Check them before handing over

Always look at the results; the test passing doesn't mean the pictures are good:

```sh
magick .build/screenshots/iphone-17-pro-dark/appstore/*.png -resize x1000 +append /tmp/…/sheet.png
```

Check for system popups over the app, the status bar (9:41, no charging bolt), clipped captions,
and that each frame shows what its caption says. On the Duo/Pro Max the drawn frames 5 and 8 are
scaled from the 17 Pro geometry.

## Change them

- **Captions and order**: the `shots` array at the top of `scripts/screenshots.sh` (output name,
  raw frame, caption, subcaption). Captions come from `plans/screenshot-shotlist.md`: six words at most.
- **Which screens**: `bergrUITests/DemoShotsTests.swift` (`shot(app, "name")` saves one).
- **What the screens show**: the demo (`HerdrKit/Sources/HerdrKit/DemoScript.swift` and the demo
  chats). Keep it generic: no real product names, people or companies.
- **Widget frames**: the views in `BergrLiveActivity/`; backdrops in `scripts/widget-render/Render.swift`,
  data in `scripts/widget-render/SiteWidgetFixture.swift`.
- **Look**: colors, fonts and geometry in the framing loop at the end of `scripts/screenshots.sh`.

## Upload

App Store Connect → Bergr → **Vertrieb (Distribution)** → the version → **App-Vorschauen und
Bildschirmfotos** → **iPhone mit Dynamic Island (mittleres Display)** → drag in
`.build/screenshots/iphone-17-pro-dark/appstore/*.png` in order. Upload from `appstore/`, never
`raw/` (unframed, with extra frames).

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
