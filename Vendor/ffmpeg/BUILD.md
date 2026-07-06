# Bundled FFmpeg (decode-only)

`ffmpeg` here is a minimal, **LGPL v2.1+**, arm64, statically-linked, **decode-only**
build of **FFmpeg 7.1.1** used as a fallback decoder for audio/video containers
AVFoundation can't read (WebM, MKV, WMA, AVI, FLV, …). It has **no network**
protocols (only `file`/`pipe`) and **no external dependencies** (only system
frameworks). Size ~2.8 MB stripped.

## Rebuild recipe
Download FFmpeg 7.1.1 source and run the exact `./configure` in `scripts` history /
`docs/audio-file-transcription/design.md` §8.2, then `make -j && strip ffmpeg`.
(See /tmp/build-ffmpeg.sh used to produce this binary.)

## Licensing (LGPL v2.1+ compliance)
- No `--enable-gpl` / `--enable-nonfree`; decode-only, no libx264/x265/etc.
- FFmpeg is shipped as a **separate executable invoked via `Process`** (not linked
  into Jot's Mach-O), so the LGPL relink obligation is trivially met.
- Ship the FFmpeg `COPYING.LGPLv2.1` license text (see NOTICE / About → Acknowledgements)
  and this recipe; offer source on request.
