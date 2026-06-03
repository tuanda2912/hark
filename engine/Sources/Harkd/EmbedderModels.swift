// EmbedderModels — the CURATED set of local text-embedding models for vault RAG
// (Phase 6 slice 4a, ADR-0032). This is the registry only; loading + inference
// live in EmbedderLoader / TextEmbedder.
//
// ADR-0032 locks two invariants this type encodes:
//   1. The embedder is chosen from a SMALL, Hark-shipped, LOCAL-ONLY set — never
//      a cloud endpoint (indexing embeds the WHOLE vault, so a cloud embedder
//      would egress all of it — the hard local-indexing invariant, rules #1/#5).
//   2. Every v1 option is 384-dim so the index schema is constant; changing the
//      embedder ⇒ full re-index (the manifest records id+revision).
//
// v1 ships ONE model wired (the multilingual default). The SECOND entry
// (bge-small-en, WordPiece) is DECLARED here so the loader + TextEmbedder
// interface are already shaped for it (ADR-0032 slice-5 requirement), but it is
// NOT downloaded or used yet — `default` is the only model the engine loads.
//
// Java analogue: an enum-backed registry of immutable config records, like a
// `@ConfigurationProperties` list of model descriptors. No behavior, just data.

import Foundation

/// Which token-pooling + prefix convention a model follows. Both curated models
/// use masked mean-pooling; they differ in tokenizer family and prefix scheme.
enum EmbedderTokenizerFamily: String, Sendable {
    /// SentencePiece Unigram (XLM-RoBERTa) — multilingual-e5. swift-transformers
    /// implements this via `UnigramTokenizer` + a Metaspace pre-tokenizer.
    case sentencePieceUnigram
    /// WordPiece (BERT) — bge-small-en / MiniLM. swift-transformers implements
    /// this via `BertTokenizer`. Declared for the slice-5 slot; unused in v1.
    case wordPiece
}

/// An immutable descriptor for one curated embedder. Everything the loader needs
/// to fetch + identify the model, and everything `TextEmbedder` needs to run it.
///
/// `Sendable` so it crosses the actor boundary into the embedder actor cleanly.
struct EmbedderModel: Sendable, Equatable {
    /// Stable id used in the index `manifest.json` (model change ⇒ re-index).
    let id: String
    /// HuggingFace repo holding the CoreML `.mlpackage` + tokenizer files. The
    /// loader downloads from here ONCE into HarkPaths (rule #2), then runs offline.
    let repo: String
    /// Pinned revision (commit sha or tag). We never track a moving `main` for a
    /// model the index depends on — a silent upstream re-convert would corrupt
    /// every stored vector. Recorded in the manifest alongside `id`.
    let revision: String
    /// Filename of the compiled/uncompiled CoreML package inside the repo.
    let mlpackageName: String
    /// Output dim. MUST be 384 for every v1 entry (fixed index schema).
    let dimension: Int
    /// Max tokens fed to the model. Longer inputs are truncated; the chunker
    /// (slice 4b) sizes chunks under this. e5 was trained at 512.
    let maxSequenceLength: Int
    /// Tokenizer family → which swift-transformers tokenizer + prefix scheme.
    let tokenizerFamily: EmbedderTokenizerFamily
    /// e5-style asymmetric prefixes. e5 REQUIRES `"query: "` on queries and
    /// `"passage: "` on indexed text — omitting them measurably hurts retrieval.
    /// bge uses an instruction prefix on the query only and none on passages; we
    /// model that as `passagePrefix == ""`.
    let queryPrefix: String
    let passagePrefix: String

    var dimensionIsValid: Bool { dimension == 384 }
}

enum EmbedderModels {
    /// `multilingual-e5-small` — the v1 DEFAULT (ADR-0032). 384-dim, multilingual
    /// (handles VI / TH / EN notes, the audience's languages). XLM-RoBERTa
    /// SentencePiece tokenizer; masked mean-pooling; e5 query/passage prefixes.
    ///
    /// The CoreML `.mlpackage` is produced by `scripts/convert-embedder-coreml.py`
    /// (validated on-device 2026-06-03 — the gated cross-lingual test passes on ANE).
    /// PRODUCTION TODO: publish `MultilingualE5Small.mlpackage` (ideally FP16-quantized
    /// to ~halve the 224 MB FP32 size) to a Hark-owned HF repo and point `repo` at it;
    /// the source repo below provides only the tokenizer files. Until then, dev/test
    /// loads the local conversion via the `HARK_EMBEDDER_LOCAL_DIR` env override
    /// (EmbedderLoader) — no hosting required.
    static let multilingualE5Small = EmbedderModel(
        id: "multilingual-e5-small",
        repo: "intfloat/multilingual-e5-small",
        // PIN: the source-weights commit we converted from. Recorded so a re-convert
        // is reproducible and the manifest can detect a model change. (Source repo
        // pin; the CoreML artifact is produced by our own recipe from this revision.)
        revision: "614241f622f53c4eeff9890bdc4f31cfecc418b3",
        mlpackageName: "MultilingualE5Small.mlpackage",
        dimension: 384,
        maxSequenceLength: 512,
        tokenizerFamily: .sentencePieceUnigram,
        queryPrefix: "query: ",
        passagePrefix: "passage: "
    )

    /// `bge-small-en-v1.5` — the English-optimized SECOND curated option
    /// (ADR-0032 slice-5). DECLARED so the loader/interface are shaped for a
    /// WordPiece model; NOT loaded in v1. bge convention: an instruction prefix on
    /// the QUERY only ("Represent this sentence for searching relevant passages: "),
    /// none on passages.
    static let bgeSmallEn = EmbedderModel(
        id: "bge-small-en-v1.5",
        repo: "BAAI/bge-small-en-v1.5",
        revision: "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a",
        mlpackageName: "BGESmallEn.mlpackage",
        dimension: 384,
        maxSequenceLength: 512,
        tokenizerFamily: .wordPiece,
        queryPrefix: "Represent this sentence for searching relevant passages: ",
        passagePrefix: ""
    )

    /// The v1 default. The only model the engine actually loads in slice 4a.
    static let `default` = multilingualE5Small

    /// The full curated set Settings will expose (slice 4c). Both are 384-dim and
    /// local-only by construction. v1 LOADS only `.default`.
    static let curated: [EmbedderModel] = [multilingualE5Small, bgeSmallEn]

    /// Look a model up by its manifest id (used when re-opening an existing index).
    static func byId(_ id: String) -> EmbedderModel? {
        curated.first { $0.id == id }
    }
}
