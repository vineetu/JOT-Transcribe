# typed: strict
# frozen_string_literal: true

# Source of truth for the cask published at vineetu/homebrew-jot (Casks/mac.rb),
# installed as `brew install --cask vineetu/jot/mac`. The token stays "mac" —
# it is what people already have installed, and renaming it would orphan them.
# scripts/publish-cask.sh copies this file into the tap.
cask "mac" do
  version "1.20.1"
  sha256 "b1bc3068d8571648f2d465ee08e99613c9a34b63873dd12c968eede8183498e5"

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
  # Raised from :sonoma — the deployment floor moved to macOS 15 when the app
  # adopted CoreMLLLM for on-device search, so a Sonoma install would fail to
  # launch. The bare symbol IS the minimum-version form; the `">= :sequoia"`
  # string spelling is deprecated and warns on every brew command.
  depends_on macos: :sequoia

  app "Jot.app"
  # The helper is named `jot-cli` inside the bundle, so no `target:` is needed
  # and Homebrew tracks it as an ordinary artifact. Naming it `jot-cli` at the
  # source (rather than renaming it here) matters: `target:` makes Homebrew
  # write a `kMDItemAlternateNames` xattr onto the file, and macOS App
  # Management forbids writing inside another app's signed bundle, which aborts
  # the whole install. It is also not `jot` because macOS ships /usr/bin/jot.
  binary "#{appdir}/Jot.app/Contents/Helpers/jot-cli"

  zap trash: [
    "~/Library/Application Support/Jot",
    "~/Library/Caches/com.jot.Jot",
    "~/Library/HTTPStorages/com.jot.Jot",
    "~/Library/Preferences/com.jot.Jot.plist",
    "~/Library/Saved Application State/com.jot.Jot.savedState",
  ]

  caveats <<~EOS
    The command-line transcriber is on your PATH as `jot-cli`
    (not `jot` — macOS already uses that name):

      jot-cli doctor           what's installed, as JSON
      jot-cli setup            download whatever is missing
      jot-cli setup --wizard   the interactive version
  EOS
end
