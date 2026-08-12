# typed: strict
# frozen_string_literal: true

# Source of truth for the cask published at vineetu/homebrew-jot (Casks/mac.rb),
# installed as `brew install --cask vineetu/jot/mac`. The token stays "mac" —
# it is what people already have installed, and renaming it would orphan them.
# scripts/publish-cask.sh copies this file into the tap.
cask "mac" do
  version "1.19"
  sha256 "eeb940989d008498376b9d81b8fb2f0b36d65b6432a1d424f20b8af377263b10"

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
  # The CLI already ships inside the bundle (Contents/Helpers/jot) — this only
  # puts it on PATH. Installed as `jot-cli`, NOT `jot`: macOS has its own
  # /usr/bin/jot (the BSD sequential-data utility) and homebrew-core has an
  # unrelated `jot` formula, so that name would shadow one and collide with
  # the other.
  binary "#{appdir}/Jot.app/Contents/Helpers/jot", target: "jot-cli"

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
