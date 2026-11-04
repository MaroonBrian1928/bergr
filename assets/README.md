# Assets

`logo.svg` is Hirte's own mark: a prompt chevron with a shepherd's crook as the cursor
("Hirte" is German for shepherd). It uses herdr's colors to show the two belong together,
but none of herdr's artwork.

`just icon` renders the app icons in `hirte/Assets.xcassets/AppIcon.appiconset` from it:

- `icon-light.png`: the logo as is (`#303438` on `#d9dad8`)
- `icon-dark.png`: colors swapped for the dark home screen
- `icon-tinted.png`: white on black; iOS tints it with the user's color

Debug builds are a separate app, "Hirte Dev" (`com.pavelzw.hirte.dev`), so they install next to the
TestFlight/App Store one. Its icons in `AppIcon-Dev.appiconset` are the same mark in amber (`#f2b33d`),
also rendered by `just icon`.
