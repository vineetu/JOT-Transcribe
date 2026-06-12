# Homebrew distribution

Two paths. The tap works **today**; the main homebrew-cask repo is the end goal
once the project is "notable" by their audit metrics (roughly ≥75 GitHub stars /
≥30 forks — new casks below that get auto-rejected).

## Path 1 — our own tap (live now)

The tap repo holds `Casks/mac.rb` (master copy: `marketing/distribution/homebrew/Casks/mac.rb`).
The cask token is `mac` so the marketed command reads as "vineetu's jot for mac".
Users install with:

```
brew install --cask vineetu/jot/mac
```

Once the tap exists under the brand account, put that one-liner on the website
download section and the README — `brew install` is the #1 install path for the
HN/dev crowd and doubles as social proof.

To recreate the tap under the `vineetu` account (2 minutes, do it before
publicizing the command so the marketed name never changes):

```
gh repo create vineetu/homebrew-jot --public --description "Homebrew tap for Jot"
git clone https://github.com/vineetu/homebrew-jot && cd homebrew-jot
mkdir -p Casks && cp <this-repo>/marketing/distribution/homebrew/Casks/jot.rb Casks/
git add -A && git commit -m "jot 1.13.1" && git push
```

### Release-time bump (add to the release checklist)

The cask pins a version + sha256, so every release needs a tap bump:

```
curl -sL -o /tmp/Jot.dmg "https://github.com/vineetu/JOT-Transcribe/releases/download/v<VER>/Jot.dmg"
shasum -a 256 /tmp/Jot.dmg
# edit Casks/mac.rb in the tap: version "<VER>", sha256 "<NEW>"
git -C <tap> commit -am "jot <VER>" && git -C <tap> push
```

(Sparkle still auto-updates existing installs either way — `auto_updates true`
tells brew not to fight it. A stale cask only affects *new* installs.)

## Path 2 — homebrew/homebrew-cask main repo (when notable)

When stars cross ~75:

```
brew tap homebrew/cask
cp marketing/distribution/homebrew/Casks/mac.rb $(brew --repository homebrew/cask)/Casks/j/jot.rb
# rename the token back: cask "mac" → cask "jot" (a generic token like "mac"
# would never be accepted in the main repo; "jot" was free as of 2026-06-11)
brew audit --cask --new jot && brew style --fix jot
# then: fork homebrew/homebrew-cask, commit to a branch, open PR titled "Add jot 1.x"
```

The cask token `jot` was free in homebrew-cask as of 2026-06-11 (checked
`Casks/j/jot.rb` → 404). If someone takes it first, fall back to `jot-dictation`.

Acceptance notes: app is Developer-ID signed + notarized (required), versioned
stable URL (required — `releases/latest` URLs are rejected, ours is versioned),
arm64-only and macOS 14+ are both declared, MIT-licensed open source helps.
