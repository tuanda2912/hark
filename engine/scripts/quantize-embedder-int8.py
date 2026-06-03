#!/usr/bin/env python3
"""Quantize Hark's CoreML embedder (MultilingualE5Small) fp16 -> int8 weights.

The base conversion (convert-embedder-coreml.py) already produces fp16 weights
(~224 MB) — coremltools' mlprogram default. To roughly HALVE the one-time
download (~112 MB) we linearly quantize the weights to int8. This is OPTIONAL
and MUST be validated: embedding quality (esp. cross-lingual VI/TH/EN retrieval)
must hold, else we ship the fp16 model instead. Run the gated Swift test against
the output dir to validate:

    HARK_TEST_EMBEDDER=1 HARK_EMBEDDER_LOCAL_DIR=/tmp/hark-coreml/int8 \
        swift test --filter EmbedderTests

Also does a direct fp16-vs-int8 fidelity check (cosine of pooled+normalized
embeddings on a few sentences) and prints it — >~0.99 means faithful.
"""
import os
import shutil
import numpy as np
import coremltools as ct
import coremltools.optimize.coreml as cto

SRC_DIR = "/tmp/hark-coreml/out"
SRC_PKG = os.path.join(SRC_DIR, "MultilingualE5Small.mlpackage")
OUT_DIR = "/tmp/hark-coreml/int8"
OUT_PKG = os.path.join(OUT_DIR, "MultilingualE5Small.mlpackage")

os.makedirs(OUT_DIR, exist_ok=True)

print("Loading fp16 mlpackage …")
mlmodel = ct.models.MLModel(SRC_PKG)

print("Linearly quantizing weights -> int8 (per-channel, symmetric) …")
op_config = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", weight_threshold=512)
config = cto.OptimizationConfig(global_config=op_config)
qmodel = cto.linear_quantize_weights(mlmodel, config=config)
qmodel.save(OUT_PKG)
print("SAVED", OUT_PKG)

# Copy the tokenizer files alongside so the Swift loader finds them.
for f in ("tokenizer.json", "tokenizer_config.json", "sentencepiece.bpe.model", "special_tokens_map.json"):
    src = os.path.join(SRC_DIR, f)
    if os.path.exists(src):
        shutil.copy2(src, os.path.join(OUT_DIR, f))
print("Copied tokenizer files to", OUT_DIR)


def size_mb(pkg):
    total = 0
    for root, _, files in os.walk(pkg):
        for fn in files:
            total += os.path.getsize(os.path.join(root, fn))
    return total / (1024 * 1024)


print(f"fp16 size: {size_mb(SRC_PKG):.1f} MB   int8 size: {size_mb(OUT_PKG):.1f} MB")

# ── Fidelity check: pooled+L2-normalized embedding cosine, fp16 vs int8 ──
# Mirrors Hark's Swift pooling (masked-mean-pool over last_hidden_state, then
# L2-normalize) so the number reflects what retrieval actually uses.
from transformers import AutoTokenizer  # noqa: E402

tok = AutoTokenizer.from_pretrained(SRC_DIR)
SENTS = [
    "query: what did we decide about the budget?",
    "passage: Ngân sách quý này đã được phê duyệt.",      # vi
    "passage: เราตัดสินใจเรื่องงบประมาณแล้ว",               # th
    "passage: The roadmap slipped by two weeks.",
]


def embed(model, text):
    enc = tok(text, return_tensors="np", padding=False, truncation=True, max_length=512)
    ids = enc["input_ids"].astype(np.int32)
    mask = enc["attention_mask"].astype(np.int32)
    out = model.predict({"input_ids": ids, "attention_mask": mask})
    hidden = np.asarray(out["last_hidden_state"])[0]      # [L, 384]
    m = mask[0][:, None].astype(np.float32)
    pooled = (hidden * m).sum(0) / np.clip(m.sum(0), 1e-9, None)
    n = np.linalg.norm(pooled)
    return pooled / (n if n > 0 else 1.0)


fp16 = ct.models.MLModel(SRC_PKG)
int8 = ct.models.MLModel(OUT_PKG)
print("\nfp16-vs-int8 embedding cosine (>~0.99 = faithful):")
worst = 1.0
for s in SENTS:
    a, b = embed(fp16, s), embed(int8, s)
    cos = float(np.dot(a, b))
    worst = min(worst, cos)
    print(f"  {cos:.5f}  {s[:48]}")
print(f"\nworst-case cosine: {worst:.5f}  -> {'SHIP int8' if worst >= 0.99 else 'KEEP fp16 (int8 drifted)'}")
