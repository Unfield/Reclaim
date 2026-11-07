# Template for the cask in https://github.com/Unfield/homebrew-tap.
# The Release workflow fills in __VERSION__ and __SHA256__ and pushes it there.
cask "reclaim" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/Unfield/Reclaim/releases/download/v#{version}/Reclaim-#{version}.dmg"
  name "Reclaim"
  desc "Free, open-source disk cleanup and system monitor"
  homepage "https://github.com/Unfield/Reclaim"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Reclaim.app"
  binary "#{appdir}/Reclaim.app/Contents/Helpers/reclaim"

  zap trash: [
    "~/Library/Application Support/Reclaim",
    "~/Library/Caches/io.github.unfield.reclaim",
    "~/Library/HTTPStorages/io.github.unfield.reclaim",
    "~/Library/Preferences/io.github.unfield.reclaim.plist",
  ]

  caveats <<~EOS
    Reclaim isn't notarized by Apple yet. If macOS refuses to open it, run:
      xattr -dr com.apple.quarantine "#{appdir}/Reclaim.app"
  EOS
end
