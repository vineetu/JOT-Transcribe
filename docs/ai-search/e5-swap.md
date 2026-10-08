# AI search: EmbeddingGemma → multilingual-e5-small (v1.23.4)

## Why

EmbeddingGemma-300M ships under the Gemma Terms of Use (use restrictions,
pass-through terms, Google can restrict use), which some organisations'
model-license policies don't allow. `intfloat/multilingual-e5-small`
(Microsoft) is MIT, multilingual, and about a third of the download. iPhone Jot
stays on EmbeddingGemma for now; the indexes are per-device and never shared.

## What changed

- `Sources/Search/Embeddings/E5EmbeddingService.swift` replaces
  `EmbeddingGemmaService.swift`. Same surface (`encode(_:role:)`, `prewarm`,
  `isDownloaded`, `modelVersion`); 384-d instead of 256-d.
- The CoreML-LLM package is gone; Jot depends on swift-transformers'
  `Tokenizers` product directly (1.3.3, already resolved before).
- `modelVersion` = `e5-small-int8-384-v1`. Gemma rows (`embeddinggemma-300m-256`)
  and the `Models/EmbeddingGemma` folder are purged at launch; `backfillMissing()`
  re-indexes the library in the background.
- Chunks grow from ~110 to ~220 tokens (window 128 → 256).
- Cut-offs: list search 0.35 → **0.81**, Ask Jot 0.30 → **0.80** (below).

## The model bundle

One zip, `multilingual-e5-small.zip` (113 MB, SHA-256
`e50e22b88757bc03b5e3e7fb09373b3ce350e3d9470dfd47db14f6bbb5cfa1f2`), unpacking to
`multilingual-e5-small/`: `encoder.mlmodelc`, `tokenizer.json`,
`tokenizer_config.json`, `special_tokens_map.json`, `config.json`,
`jot-model.json`, `LICENSE` (MIT), `NOTICE`.

Published as GitHub release `models-e5-small-v1` on `vineetu/JOT-Transcribe`
(Info.plist `JOT_SEARCH_MODEL_URL`, also the code default). A flavor build can
point `JOT_SEARCH_MODEL_URL` at another host serving the same zip; the app
checks the SHA-256 before installing, whatever the host.

## Conversion (reproducible)

Scripts in `tools/e5-search-model/`. Environment that works (newer torch /
transformers break coremltools 9):

```sh
uv venv -p python3.12 .venv
uv pip install -p .venv/bin/python coremltools==9.0 torch==2.7.0 transformers==4.46.3 "numpy<2.3" sentencepiece pandas pyarrow huggingface_hub
.venv/bin/python convert.py 256      # fp16 mlpackage + parity vs PyTorch
.venv/bin/python quant.py            # int8 per-channel weights + parity vs fp16
xcrun coremlcompiler compile e5-small-256-int8.mlpackage out/   # → encoder.mlmodelc
```

The wrapper folds attention-masked mean pooling + L2 normalisation into the
model. **The attention mask must be built with -1e4**, not the library's
float32 minimum: in fp16 the latter overflows and every input embeds to nearly
the same vector (cosine to PyTorch fell to ~0.72 before the fix, 0.99996 after).
int8 vs fp16: cosine ≥ 0.9998, rankings unchanged.

## Swift parity

`E5SelfTest` (DEBUG): `JOT_E5_SELFTEST=tools/e5-search-model/e5-fixtures.json`
runs 17 fixtures (English, French, Spanish, German, Japanese, Chinese, Korean,
Arabic, Hindi, Russian, Turkish, Vietnamese, symbols/emoji, ligatures and
full-width, whitespace, a >256-token passage). swift-transformers' XLM-R
tokenizer produced identical ids for all 17; embeddings match the Python Core ML
output at cosine ≥ 0.9997. `JOT_SEARCH_MODEL_URL_OVERRIDE=file://…zip` exercises
the download → checksum → unpack path; a tampered zip is refused and nothing
is installed.

## Cut-offs (public data only)

`tune.py` scores both models on MIRACL reranking dev (`mteb/MIRACLReranking`,
CC BY-SA 4.0): 30 queries each in en es fr de ru fi ja zh ko ar hi, 498
judged-relevant passages, judged non-relevant "hard" passages from the same
query, and "easy" passages relevant to a different query. It carries over the
operating point Gemma shipped with:

| | recall (relevant kept) | hard let through | unrelated let through |
|---|---|---|---|
| Gemma @ 0.35 (list) | 99.0% | 80.0% | 0.3% |
| **e5 @ 0.81 (list)** | 99.2% | 80.7% | 0.6% |
| Gemma @ 0.30 (Ask Jot) | 99.8% | 87.9% | 0.3% |
| **e5 @ 0.80 (Ask Jot)** | 99.6% | 86.3% | 2.1% |

e5 scores run high (unrelated text still ~0.73 median), so cut-offs are not
comparable across models. Owner recordings were not used.
