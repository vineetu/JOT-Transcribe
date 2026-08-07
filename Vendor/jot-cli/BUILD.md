# `jot` CLI helper binary

`Vendor/jot-cli/jot` is the pre-built, self-contained `jot` command-line
transcriber (source: `tools/jot-cli/`). It is bundled into
`Jot.app/Contents/Helpers/jot` (signed, hardened runtime) by the
"Bundle Helpers" build phase — the same pattern as `Vendor/ffmpeg/ffmpeg`.

It is **self-contained**: `otool -L` shows no non-system dylibs (FluidAudio,
the jot-shared packages, and the Swift runtime are statically linked), and it
needs no sidecar resource bundle beyond the JotVocabCore common-word lists SPM
embeds. At runtime it finds `ffmpeg` as its sibling in `Contents/Helpers/`
and loads transcription models from the app's model dir
(`~/Library/Application Support/Jot/Models/`). It never downloads models.

## Rebuild (after changing `tools/jot-cli/`)

Requires the `jot-shared` repo checked out as a sibling of this repo
(`../jot-shared` from the repo root) — `tools/jot-cli/Package.swift` declares
it as a local-path dependency, the same convention the app target uses.
The v0.2 CLI needs jot-shared at or past the `PostProcessing` addition
(branch `claude/jot-cli-v2` until merged).

```sh
cd tools/jot-cli
swift build -c release
cp .build/release/jot ../../Vendor/jot-cli/jot
chmod 755 ../../Vendor/jot-cli/jot
```

Then rebuild the app; the "Bundle Helpers" phase re-copies + re-signs it.

> **Stale-binary note:** if `tools/jot-cli/` sources are newer than this
> binary, the bundle ships the old behavior until someone reruns the steps
> above on a Mac. (The v0.2 sources — plain-text default, cleanup chain,
> vocabulary, `--stream` — need this rebuild; the checked-in binary is
> still v0.1.)

## Usage

```
jot transcribe <file> [--vtt] [--diarize] [--raw] [--no-vocab] [--language <code>] [-o out]
jot --stream [--language <code>] [--rate 16000] [--encoding s16le|f32le]
```

Default `transcribe` output is cleaned plain text; `--vtt` / `--diarize`
restore WebVTT cues (`--diarize` needs the diarizer model — run "Detect
speakers" in the app once to download it). `--stream` reads 16 kHz mono PCM
on stdin and emits `{"type":"final","text":"..."}` NDJSON lines as segments
commit. Full reference: `tools/jot-cli/jot-cli.1` (`man ./jot-cli.1`).
