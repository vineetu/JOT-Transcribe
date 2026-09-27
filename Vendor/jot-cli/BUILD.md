# `jot` CLI helper binary

`Vendor/jot-cli/jot` is the pre-built, self-contained `jot` command-line
transcriber (source: `tools/jot-cli/`). It is bundled into
`Jot.app/Contents/Helpers/jot-cli` (signed, hardened runtime) by the
"Bundle Helpers" build phase — the same pattern as `Vendor/ffmpeg/ffmpeg`.

It is **self-contained**: `otool -L` shows no non-system dylibs (FluidAudio and
the Swift runtime are statically linked), and it needs no sidecar resource
bundle. At runtime it finds `ffmpeg` as its sibling in `Contents/Helpers/` and
loads transcription/diarization models from the app's model dir
(`~/Library/Application Support/Jot/Models/`). `transcribe` (including
`--diarize`) and `batch --vad` never download; `jot-cli setup` fetches models,
and `--stream` still downloads its own on first run.

## Rebuild (after changing `tools/jot-cli/`)

```sh
cd tools/jot-cli
swift build -c release
cp .build/release/jot ../../Vendor/jot-cli/jot
chmod 755 ../../Vendor/jot-cli/jot
```

Then rebuild the app; the "Bundle Helpers" phase re-copies + re-signs it.
`release.sh` does this rebuild itself, but a plain `xcodebuild` test install
does NOT — rebuild `Vendor/jot-cli/jot` by hand first whenever `tools/jot-cli/`
(or the shared `Sources/Diarization/DiarizationProjection.swift` it symlinks)
changed, or the installed app ships a stale CLI.

## Usage

```
jot-cli transcribe <file> [--diarize] [-o out.vtt]
```
Output is WebVTT. `--diarize` adds `<v Speaker N>` voice tags (needs the
Nemotron 3 diarizer model, ~190 MB — `jot-cli setup --components diarizer`, or
run "Detect speakers" in the app once).
