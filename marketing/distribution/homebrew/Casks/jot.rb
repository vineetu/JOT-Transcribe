cask "jot" do
  version "1.13.1"
  sha256 "21ecb0624d25e879488d467a075a41918c883c468d702862a3fdc4ad0d76e0f3"

  url "https://github.com/vineetu/JOT-Transcribe/releases/download/v#{version}/Jot.dmg",
      verified: "github.com/vineetu/JOT-Transcribe/"
  name "Jot"
  desc "Free, open-source, on-device dictation utility"
  homepage "https://jot-transcribe.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Jot.app"

  zap trash: [
    "~/Library/Application Support/Jot",
    "~/Library/Caches/com.jot.Jot",
    "~/Library/HTTPStorages/com.jot.Jot",
    "~/Library/Preferences/com.jot.Jot.plist",
  ]
end
