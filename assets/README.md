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
