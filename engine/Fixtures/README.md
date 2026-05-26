# Fixtures

Audio files used by the Phase 0 benchmark.

**This directory is gitignored** for audio files — never commit real meeting
audio, identifiable voices, or anything from a corporate call. Hark's
privacy posture is the product; leaking a fixture would undermine it.

You need **one** audio file roughly 60 seconds long, ideally 5+ minutes
for stable percentile readings. WhisperKit will accept `.wav`, `.mp3`,
`.m4a`, `.flac` and resample to 16 kHz mono internally.

## Where to get a fixture (in order of preference)

### Option 1 — Synthetic via macOS `say` (fastest, zero download)

Generates a clean spoken sample. Good for a smoke test, **not** a
realistic benchmark — synthetic speech is unnaturally easy for Whisper.

```bash
# 30 seconds of sample text. Add more --- to lengthen.
say -v Samantha -o sample.aiff \
  "This is a synthetic test of the Hark transcription engine. \
   We are measuring real time factor on Apple Silicon hardware. \
   The benchmark loads the WhisperKit large-v3-turbo model and \
   feeds audio in thirty second windows. Pass criterion is point \
   five real time factor. If this works we proceed to phase one."

# WhisperKit accepts aiff directly; convert to wav if you prefer.
afconvert -f WAVE -d LEI16@16000 sample.aiff sample.wav
```

Then:

```bash
swift run -c release hark-bench Fixtures/sample.wav
```

### Option 2 — LibriSpeech sample (public domain, realistic English)

Free, no signup, ~few hundred MB for the dev-clean subset.

```bash
# Grab a single FLAC file (about 5–10 seconds each) — concatenate a few
# for a longer fixture, or download a chapter.
curl -O https://www.openslr.org/resources/12/dev-clean.tar.gz
tar xf dev-clean.tar.gz
# Pick any .flac, or sox-concat a few:
sox LibriSpeech/dev-clean/*/*/*.flac long-en.wav trim 0 300
```

### Option 3 — Mozilla Common Voice clips (CC0)

Real human speakers, varied accents, varied audio quality (closer to
realistic meetings). https://commonvoice.mozilla.org/en/datasets

### Option 4 — Your own recording (NOT for sharing)

If you record your own voice locally for benchmarking, that's fine and
appropriate — **just don't commit it**. The `.gitignore` here covers
`.wav .mp3 .m4a .flac` so accidental `git add` won't catch it, but
double-check before pushing.

## Recommended fixture set (eventually)

The full benchmark suite per
[`vault/docs/qa/10-performance-benchmarks.md`](~/Documents/vault/hark/docs/qa/10-performance-benchmarks.md)
calls for:

- `long-en.wav` — clean English, ~10 min
- `long-en-noisy.wav` — same content with room noise mixed in
- `long-th-en.wav` — Thai-English code-switch (the actual use case)
- `3speakers.wav` — three distinct voices

Phase 0 only needs one of these — start with whichever you can produce
fastest. Build the rest as you need them.
