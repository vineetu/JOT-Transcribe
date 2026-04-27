#!/usr/bin/env bash
# gen-ja-samples.sh
#
# Generate 20 Japanese audio fixtures for the empirical Parakeet JA punctuation
# check (Phase 4 / docs/plans/japanese-support.md item 12). Each fixture is a
# 16 kHz mono 16-bit WAV produced by macOS's `say` + `afconvert` pipeline so
# the harness can run them through the Parakeet JA model and inspect what
# punctuation glyphs the decoder emits.
#
# Sentences cover the four punctuation cases that matter for the check:
#   periods (。), question marks (？), exclamations (！), commas (、),
# plus a mix of declaratives and longer sentences for sample variety.
#
# Voice: Kyoko only. Other macOS Japanese voices (Eddy, Flo, etc.) shipped on
# this Mac do NOT actually synthesize the JP text — they fall back to a
# silent/empty utterance, producing 4608-byte WAVs with ~0.016s duration.
# Kyoko is the only voice that produces real Japanese speech, so we pin to it.
#
# Output: writes ja-01.wav through ja-20.wav into the fixtures directory
# (default: Tests/JotHarness/Fixtures/audio). Idempotent — running again
# overwrites cleanly.
#
# Usage:
#   scripts/gen-ja-samples.sh                 # default fixture dir
#   scripts/gen-ja-samples.sh /tmp/ja-out     # custom dir

set -euo pipefail

OUT_DIR="${1:-/Users/vsriram/code/jot/Tests/JotHarness/Fixtures/audio}"
mkdir -p "$OUT_DIR"

declare -a SENTENCES=(
  "こんにちは。"
  "今日はいい天気ですね。"
  "今何時ですか？"
  "すごい！"
  "私は学生です。"
  "本を読みます。"
  "明日は雨が降るでしょう。"
  "ありがとうございました。"
  "もう一度言ってください。"
  "それは何ですか？"
  "彼は学校に行きました。"
  "猫が好きです。"
  "今、忙しいです。"
  "頑張ってください！"
  "どこに行きますか？"
  "これは美味しいですね。"
  "音楽を聴いています。"
  "ご飯を食べました。"
  "もう寝る時間です。"
  "電車が遅れています。"
)

declare -a VOICES=("Kyoko")

i=0
for sentence in "${SENTENCES[@]}"; do
  i=$((i + 1))
  voice=${VOICES[$(( (i - 1) % ${#VOICES[@]} ))]}
  num=$(printf "%02d" "$i")
  aiff_path="/tmp/ja-${num}.aiff"
  wav_path="${OUT_DIR}/ja-${num}.wav"

  say -v "$voice" -o "$aiff_path" "$sentence"
  # Convert AIFF (typically 22050 Hz, 16-bit, mono) to canonical 16 kHz mono
  # LINEAR16 WAV. Jot's harness `decodeFile(_:)` slow path further converts
  # to Float32 at load time.
  afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff_path" "$wav_path"
  rm -f "$aiff_path"
  echo "  ja-${num}.wav  voice=${voice}  text=\"${sentence}\""
done

echo
echo "Generated ${i} JA fixtures in ${OUT_DIR}"
