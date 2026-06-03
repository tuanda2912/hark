#!/usr/bin/env bash
# Publish Hark's int8 CoreML embedder to a Hark-owned HuggingFace repo so the
# engine can download it at first run (ADR-0032/0034 deploy step). Requires YOUR
# HuggingFace account — this is the one step Claude can't do for you.
#
# Prereqs:
#   1. The int8 artifact staged at $STAGING (run convert-embedder-coreml.py then
#      quantize-embedder-int8.py if /tmp/hark-coreml/int8 is gone — see below).
#   2. The HuggingFace CLI installed + logged in:
#        pip install -U "huggingface_hub[cli]"   &&   hf auth login   # (or: huggingface-cli login)
#
# Usage:
#   engine/scripts/publish-embedder-hf.sh <your-hf-namespace>/hark-multilingual-e5-small-coreml
#
# After it prints the commit SHA, paste that SHA (and the repo id) back so the
# repo + revision can be pinned in EmbedderModels.swift.
set -euo pipefail

REPO_ID="${1:-}"
STAGING="${HARK_EMBEDDER_LOCAL_DIR:-/tmp/hark-coreml/int8}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARD="$SCRIPT_DIR/embedder-model-card.md"

if [[ -z "$REPO_ID" ]]; then
  echo "usage: $0 <hf-namespace>/<repo-name>   (e.g. tuanda2912/hark-multilingual-e5-small-coreml)" >&2
  exit 2
fi

# ── Staging sanity: the int8 package + tokenizer must be present. ────────────
PKG="$STAGING/MultilingualE5Small.mlpackage"
if [[ ! -d "$PKG" ]]; then
  cat >&2 <<EOF
error: int8 artifact not found at $PKG

Regenerate it (needs the Python venv from the conversion step):
  /tmp/hark-coreml/venv/bin/python $SCRIPT_DIR/convert-embedder-coreml.py     # -> /tmp/hark-coreml/out (fp16)
  /tmp/hark-coreml/venv/bin/python $SCRIPT_DIR/quantize-embedder-int8.py      # -> /tmp/hark-coreml/int8 (int8, validated)
Or set HARK_EMBEDDER_LOCAL_DIR to a dir that already holds MultilingualE5Small.mlpackage + tokenizer.
EOF
  exit 1
fi
for f in tokenizer.json tokenizer_config.json special_tokens_map.json sentencepiece.bpe.model; do
  [[ -f "$STAGING/$f" ]] || { echo "error: missing tokenizer file $STAGING/$f" >&2; exit 1; }
done

# ── Pick the HF CLI (new unified `hf`, else legacy `huggingface-cli`). ───────
if command -v hf >/dev/null 2>&1; then HF=hf
elif command -v huggingface-cli >/dev/null 2>&1; then HF=huggingface-cli
else echo "error: HuggingFace CLI not found. Run: pip install -U 'huggingface_hub[cli]'" >&2; exit 1; fi

echo "Using $HF as $($HF auth whoami 2>/dev/null || $HF whoami 2>/dev/null || echo '<not logged in — run: '"$HF"' auth login>')"

# Drop the model card in as the repo README (idempotent).
cp "$CARD" "$STAGING/README.md"

echo "Uploading $STAGING -> https://huggingface.co/$REPO_ID (this can take a minute for ~113 MB)…"
"$HF" upload "$REPO_ID" "$STAGING" . \
  --repo-type model \
  --commit-message "Add int8 CoreML multilingual-e5-small for Hark vault RAG"

# ── Report the commit SHA to pin. ────────────────────────────────────────────
echo ""
echo "Fetching the published commit SHA…"
SHA="$(curl -fsSL "https://huggingface.co/api/models/$REPO_ID" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sha",""))' 2>/dev/null || true)"

echo ""
echo "────────────────────────────────────────────────────────────────────"
echo "Published: https://huggingface.co/$REPO_ID"
if [[ -n "$SHA" ]]; then
  echo "Pinned revision (commit SHA): $SHA"
  echo ""
  echo "Now set these in engine/Sources/Harkd/EmbedderModels.swift (multilingualE5Small):"
  echo "    repo:     \"$REPO_ID\""
  echo "    revision: \"$SHA\""
else
  echo "Could not auto-fetch the SHA — open https://huggingface.co/$REPO_ID/commits/main"
  echo "and copy the latest commit SHA, then set repo + revision in EmbedderModels.swift."
fi
echo "────────────────────────────────────────────────────────────────────"
