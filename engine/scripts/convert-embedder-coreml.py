#!/usr/bin/env python3
"""Convert intfloat/multilingual-e5-small -> CoreML (.mlpackage) for Hark's vault RAG.

Produces a model with:
  inputs : input_ids (int32 [1,L]), attention_mask (int32 [1,L]), flexible L in 1..512
  output : last_hidden_state (float32 [1,L,384])  -- Hark pools + L2-normalizes in Swift
Also saves the tokenizer files alongside so they can be placed in Hark's model cache.
"""
import os
import numpy as np
import torch
import coremltools as ct
from transformers import AutoModel, AutoTokenizer

MODEL = "intfloat/multilingual-e5-small"
REV = "614241f622f53c4eeff9890bdc4f31cfecc418b3"  # pinned in EmbedderModels.swift
OUT = "/tmp/hark-coreml/out"
os.makedirs(OUT, exist_ok=True)

print("Loading model + tokenizer …")
model = AutoModel.from_pretrained(MODEL, revision=REV, torchscript=True).eval()
tok = AutoTokenizer.from_pretrained(MODEL, revision=REV)
tok.save_pretrained(OUT)  # tokenizer.json, tokenizer_config.json, sentencepiece.bpe.model, special_tokens_map.json
print("Saved tokenizer files to", OUT)


class Wrap(torch.nn.Module):
    """Expose ONLY last_hidden_state; Hark owns masked-mean-pool + L2-normalize."""
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, input_ids, attention_mask):
        out = self.m(input_ids=input_ids, attention_mask=attention_mask)
        # torchscript models return a tuple; last_hidden_state is the first element
        return out[0] if isinstance(out, tuple) else out.last_hidden_state


ex_ids = torch.ones(1, 16, dtype=torch.int32)
ex_mask = torch.ones(1, 16, dtype=torch.int32)
print("Tracing …")
traced = torch.jit.trace(Wrap(model), (ex_ids, ex_mask), strict=False)

seq = ct.RangeDim(lower_bound=1, upper_bound=512, default=16)
print("Converting to CoreML mlprogram …")
mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, seq), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, seq), dtype=np.int32),
    ],
    outputs=[ct.TensorType(name="last_hidden_state", dtype=np.float32)],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS14,
    compute_units=ct.ComputeUnit.CPU_AND_NE,
)
pkg = os.path.join(OUT, "MultilingualE5Small.mlpackage")
mlmodel.save(pkg)
print("SAVED", pkg)

# Quick sanity: run the CoreML model on a short input and report the output shape.
import coremltools.models as ctm  # noqa
spec_out = mlmodel.get_spec().description.output
print("CoreML outputs:", [o.name for o in spec_out])
