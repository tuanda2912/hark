---
license: mit
language:
  - multilingual
  - en
  - vi
  - th
library_name: coreml
tags:
  - coreml
  - embeddings
  - sentence-similarity
  - retrieval
  - hark
base_model: intfloat/multilingual-e5-small
---

# multilingual-e5-small — CoreML (int8) for Hark

A **CoreML** (`mlprogram`, **int8-weight-quantized**) conversion of
[`intfloat/multilingual-e5-small`](https://huggingface.co/intfloat/multilingual-e5-small)
(384-dim, multilingual), packaged for on-device vault search in
[**Hark**](https://github.com/tuanda2912/hark) — a local-first, macOS-only meeting
transcription app. Runs on the Apple Neural Engine; **nothing is sent off the
machine** (Hark embeds the whole vault locally).

This repo exists so Hark can download a ready-to-run CoreML artifact instead of
shipping it in the app bundle. It is a faithful conversion — see *Provenance* and
*Validation* — not a new model.

## Files

| File | What |
|---|---|
| `MultilingualE5Small.mlpackage/` | the CoreML model (int8 weights, ~113 MB) |
| `tokenizer.json`, `tokenizer_config.json`, `special_tokens_map.json` | XLM-RoBERTa tokenizer (SentencePiece Unigram) |
| `sentencepiece.bpe.model` | the SentencePiece model |

Hark's loader snapshots this repo at a **pinned revision** into its app-support
models dir, compiles the `.mlpackage` to the ANE, and runs fully offline
thereafter.

## I/O contract

- **inputs:** `input_ids` (int32 `[1, L]`), `attention_mask` (int32 `[1, L]`), flexible `L ∈ 1..512`
- **output:** `last_hidden_state` (float32 `[1, L, 384]`)
- Hark applies **masked mean-pooling + L2-normalization** in Swift, and the e5
  asymmetric prefixes (`"query: "` / `"passage: "`). Reproduce those if you reuse
  this model directly.

## Provenance

- Converted from `intfloat/multilingual-e5-small` at source revision
  **`614241f622f53c4eeff9890bdc4f31cfecc418b3`** via
  [`engine/scripts/convert-embedder-coreml.py`](https://github.com/tuanda2912/hark/blob/main/engine/scripts/convert-embedder-coreml.py)
  (coremltools 9, `convert_to="mlprogram"`, `minimum_deployment_target=macOS14`).
- int8 weight quantization (per-channel, symmetric) via
  [`engine/scripts/quantize-embedder-int8.py`](https://github.com/tuanda2912/hark/blob/main/engine/scripts/quantize-embedder-int8.py)
  (`coremltools.optimize.coreml.linear_quantize_weights`).

## Validation

- **Fidelity:** worst-case cosine between the fp16 and int8 pooled+L2-normalized
  embeddings was **0.99986** across EN/VI/TH probe sentences — the int8 weights
  are essentially indistinguishable from fp16 for retrieval.
- **On-device:** Hark's gated cross-lingual + end-to-end retrieval tests pass on
  the Apple Neural Engine with this int8 artifact (EN↔VI/TH closer than
  unrelated; full chunk → embed → index → retrieve pipeline).

## License

MIT, inherited from `intfloat/multilingual-e5-small`. This is a format conversion
+ weight quantization of that model; all credit to the original authors.
