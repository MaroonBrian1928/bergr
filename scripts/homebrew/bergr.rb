# Template of Casks/bergr.rb in the tap MaroonBrian1928/homebrew-tap.
# `just mac-release` fills in @VERSION@ and @SHA256@ and writes .build/mac/bergr.rb; copy that into the tap.
cask "bergr" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/MaroonBrian1928/bergr/releases/download/mac-v#{version}/Bergr-#{version}.dmg"
  name "Bergr"
  desc "Watch and answer coding agents running under herdr"
  homepage "https://github.com/MaroonBrian1928/bergr"

  auto_updates true
  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "Bergr.app"

  zap trash: [
    "~/Library/Preferences/com.redacted.bergr.mac.plist",
    "~/Library/Caches/com.redacted.bergr.mac",
  ]
end
