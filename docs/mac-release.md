# Releasing the Mac app

`just mac-release` builds, signs, notarizes and packages the native Mac app (plan: `plans/mac-native.md`, section 2.7).
Everything below the one-time steps is a recipe line you run yourself; nothing here runs in CI.

## One-time steps (you, in this order)

1. **App ID.** In the developer portal, create `com.example.bergr.mac` with Keychain Sharing.
2. **Developer ID Application certificate.** Create it in Xcode (Settings, Accounts, Manage Certificates) or the
   portal, so it sits in your login keychain (`security find-identity -v -p codesigning` lists it). Then a
   Developer ID provisioning profile for the App ID, or cloud-managed Developer ID signing, which needs the
   Account Holder or a permitted Admin on the API key.
3. **App Store Connect API key.** The one `just archive` uses; export `BERGR_ASC_KEY_PATH`, `BERGR_ASC_KEY_ID` and
   `BERGR_ASC_KEY_ISSUER` (`.envrc.local`). The same key drives `notarytool`.
4. **Sparkle EdDSA key.** Run `generate_keys` from Sparkle's `bin` (in the SwiftPM artifacts of a Mac build, or set
   `BERGR_SPARKLE_BIN`). The private key lands in the login keychain; export a copy
   (`generate_keys -x sparkle.key`) into sops next to the App Store Connect key, or point `BERGR_SPARKLE_KEY_FILE`
   at it. Put the printed public key into `Config/Mac-Info.plist` as `SUPublicEDKey` (empty until then, so the
   script refuses to release).
5. **Tap.** Create the repository `MaroonBrian1928/homebrew-tap` with a `Casks/` folder.

## Release

```
just mac-release-check     # steps and prerequisites, builds nothing
just mac-release           # archive, export, DMG, notarize, staple, appcast into .build/mac
just mac-release true      # the same, then gh release create mac-v<version> (DMG + appcast.xml)
```

The version is `MARKETING_VERSION` (shared with iOS); the tag is `mac-v<version>`. Afterwards copy
`.build/mac/bergr.rb` (made from `scripts/homebrew/bergr.rb`) to `Casks/bergr.rb` in the tap and push.
Check the DMG on a second Mac account: `spctl -a -t open --context context:primary-signature -v Bergr-<version>.dmg`.

The feed is `https://github.com/MaroonBrian1928/bergr/releases/latest/download/appcast.xml`
(`SUFeedURL`), so every release carries its own `appcast.xml`.
