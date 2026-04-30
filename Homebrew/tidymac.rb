# Homebrew Cask formula for TidyMac.
#
# This file lives here for source-of-truth and copy-paste convenience.
# It must be COPIED into your Homebrew tap repository to work — Homebrew
# only finds Casks under taps named `homebrew-<name>`. To set up the tap:
#
#   1. Create a public GitHub repo named `countingaces/homebrew-tap`.
#   2. Inside it, create a `Casks/` directory.
#   3. Copy this file to `Casks/tidymac.rb` in that repo.
#   4. Update the `version` and `sha256` lines for each release. The
#      release script (Scripts/create-release.sh) prints both values
#      after building.
#
# Users will then install with:
#
#   brew tap countingaces/tap
#   brew install --cask tidymac

cask "tidymac" do
  version "0.1.0"
  sha256 "PLACEHOLDER_SHA256"

  url "https://github.com/countingaces/TidyMac/releases/download/v#{version}/TidyMac-#{version}.zip"
  name "TidyMac"
  desc "Free, open-source Mac maintenance tool"
  homepage "https://github.com/countingaces/TidyMac"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "TidyMac.app"

  # `brew uninstall --zap tidymac` removes everything TidyMac touches —
  # eating our own dog food on the same Library locations Uninstaller
  # finds for other apps.
  zap trash: [
    "~/Library/Application Support/TidyMac",
    "~/Library/Preferences/com.tidymac.TidyMac.plist",
    "~/Library/Caches/com.tidymac.TidyMac",
    "~/Library/Logs/TidyMac",
    "~/Library/Saved Application State/com.tidymac.TidyMac.savedState",
    "~/Library/HTTPStorages/com.tidymac.TidyMac",
    "~/Library/WebKit/com.tidymac.TidyMac",
  ]
end
