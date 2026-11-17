# Assets

The gold light-mode icon supplied in the phone screenshot is the design baseline:
charcoal shepherd and dog on warm gold. The lower robe, dog and staff continue through
the bottom canvas edge, with no background gutter or horizontal baseline. Dark mode
uses the same silhouette and framing in gold on charcoal. Release variants retain the
ivory/charcoal palette; development variants retain gold/charcoal.

- `logo-dev-light.png`: gold light-mode master.
- `logo-dev-dark.png`: matching gold-on-charcoal dark appearance.
- `logo-light.png` and `logo-dark.png`: ivory release variants and README previews.
- `logo-tinted.png`: existing monochrome tinted source.

Run `just icon` on macOS to export opaque 1024 by 1024 icons using `scripts/icons.swift`.
Xcode selects the appearance variants; iOS supplies the rounded-corner mask.

The bottom-edge correction and palette variants were prepared with the built-in image
generation tool. The prompts preserved the light master's silhouette, head and crook
positions, proportions and framing; extended only the lower figures through the bottom;
and derived the other appearances through palette changes, without outlines or gray fills.

Design references:
- https://developer.apple.com/design/human-interface-guidelines/app-icons
- https://developer.apple.com/design/human-interface-guidelines/dark-mode

Apple recommends using the light icon as the basis for the dark icon, maintaining its
recognizable features, preserving contrast, and supplying square unmasked artwork.
The bottom-edge crop is the requested bergr composition choice, not an Apple requirement.

## Site and App Store media

Everything on the marketing site (`../bergr-site`) and in the App Store screenshots is made from the
demo, by scripts, so a design change only needs a re-run. Source `.envrc.local` first (signing).

```sh
just site-media             # all three below, in order; stops at the first failure
just site-shots             # app screens  → <site>/assets/shot-<name>-{light,dark}.jpg
just site-widgets           # widgets, Home and Lock Screen → shot-{usage-widget,home-widgets,lock-live-activity}-*.jpg
just site-video             # the tour     → demo.mp4 (832×1676, ~28 s) and demo-poster.jpg
just appstore-shots         # captioned App Store set → .build/screenshots/iphone-17-pro-dark/appstore/
```

Each takes the site folder as an argument (default `../bergr-site`). Then:

1. Look at the result: `git -C ../bergr-site diff --stat` and the page itself. If a file changed
   only by re-encoding, drop it: `git -C ../bergr-site checkout -- assets/<file>`.
2. Commit and push in the site repo; Netlify deploys it.
3. App Store: upload `.build/screenshots/iphone-17-pro-dark/appstore/*.png` in order (see
   `.claude/skills/app-store-screenshots`).

Where things come from: the screens from `bergrUITests/DemoShotsTests`, the video from
`DemoTourTests/testVideoTour` (`scripts/video.sh`, sped up by `BERGR_VIDEO_SPEED`, default 1.85), the
widgets from the real views in `BergrLiveActivity/` drawn by `scripts/widget-render/` with the data in
`SiteWidgetFixture.swift`, captions from `plans/screenshot-shotlist.md` (in `scripts/screenshots.sh`).
