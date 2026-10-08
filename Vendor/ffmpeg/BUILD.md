# Bundled FFmpeg (decode-only)

`ffmpeg` here is a minimal, **LGPL v2.1+**, arm64, statically-linked, **decode-only**
build of **FFmpeg 7.1.1** used as a fallback decoder for audio/video containers
AVFoundation can't read (WebM, MKV, WMA, AVI, FLV, …). It has **no network**
protocols (only `file`/`pipe`) and **no external dependencies** (only system
frameworks). Size ~2.8 MB stripped.

## Source

FFmpeg 7.1.1, unmodified: <https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz>
(SHA-256 `733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1`;
signature at the same URL + `.asc`).

## Build recipe

On Apple Silicon with Xcode's clang. These are the exact options the shipped
binary reports (`ffmpeg -hide_banner -buildconf`):

```sh
tar xf ffmpeg-7.1.1.tar.xz && cd ffmpeg-7.1.1
./configure \
  --arch=arm64 --cpu=host --enable-static --disable-shared \
  --disable-everything --disable-programs --enable-ffmpeg \
  --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
  --disable-network --disable-autodetect --disable-debug --enable-small \
  --disable-avdevice --disable-postproc \
  --disable-encoders --enable-encoder=pcm_s16le \
  --disable-muxers --enable-muxer=wav \
  --disable-demuxers --enable-demuxer='matroska,asf,avi,flv,ogg,mov,mp3,wav,flac,aac,ac3,eac3,aiff,w64,mpegts' \
  --disable-decoders --enable-decoder='opus,vorbis,wmav1,wmav2,aac,aac_latm,ac3,eac3,mp3,mp3float,flac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_f32le,pcm_u8,alac,vp8,vp9' \
  --disable-parsers --enable-parser='opus,vorbis,aac,aac_latm,ac3,mpegaudio,flac,vp8,vp9' \
  --disable-bsfs --enable-bsf='null,vp9_superframe,extract_extradata,aac_adtstoasc' \
  --disable-protocols --enable-protocol='file,pipe' \
  --disable-filters --enable-filter='aresample,aformat,anull,atrim,anullsink' \
  --disable-hwaccels --disable-videotoolbox --disable-audiotoolbox
make -j && strip ffmpeg
```

## Licensing (LGPL v2.1+ compliance)
- No `--enable-gpl` / `--enable-nonfree`; decode-only, no libx264/x265/etc.
- FFmpeg is shipped as a **separate executable invoked via `Process`** (not linked
  into Jot's Mach-O), so anyone can replace it with their own build.
- The license text ships inside the app
  (`Contents/Resources/ffmpeg-COPYING.LGPLv2.1`, copied by the "Bundle Helpers"
  build phase) and is credited in About → Models and open-source licenses.
- Source: the unmodified upstream tarball above plus this recipe.
