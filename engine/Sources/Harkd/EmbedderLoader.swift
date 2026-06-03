// EmbedderLoader — download (one-time) + ANE-compile + build a CoreMLTextEmbedder
// for the vault-RAG default model (Phase 6 slice 4a, ADR-0032). Mirrors
// HarkCore.ModelLoader (WhisperKit) and DiarizerLoader (FluidAudio): fetch into
// Hark's app-support models dir, compile to the Neural Engine, then hand back a
// ready, OFFLINE embedder.
//
// CRITICAL (CLAUDE.md hard rule #2): both the CoreML package AND the tokenizer
// files cache under `~/Library/Application Support/Hark/Models/`, never
// swift-transformers' default `~/Documents/huggingface/`. We force that by
// constructing `HubApi(downloadBase: HarkPaths.modelsDir())` — every snapshot it
// writes lands inside Hark's dir, and the offline tokenizer build then reads
// from that same folder. There is ONE network event in this file: the first-run
// `snapshot`. After that the embedder is fully local (embed() never networks).
//
// Lives in Harkd (not HarkCore) for the same reason DiarizerLoader does: the
// tokenizer dependency (swift-transformers) is Harkd-only; pulling it into
// HarkCore would link it into hark-bench/-engine/-capture, none of which embed.
// The cache LOCATION stays shared via HarkCore.HarkPaths.

import Foundation
import CoreML
import Hub
import Tokenizers
import HarkCore

/// Result of `loadTextEmbedder`. Carries timing so the daemon can log cold-start
/// cost the same way it does for WhisperKit + the diarizer.
struct LoadedEmbedder {
    let embedder: CoreMLTextEmbedder
    let model: EmbedderModel
    let modelDir: URL
    let downloadSeconds: Double
    let compileSeconds: Double
    let totalLoadSeconds: Double
}

enum EmbedderLoadError: Error, CustomStringConvertible {
    case mlpackageMissing(URL)
    case outputFeatureMissing(have: [String], want: String)
    case dimensionMismatch(declared: Int)

    var description: String {
        switch self {
        case .mlpackageMissing(let url):
            return "embedder CoreML package not found after download at \(url.path)"
        case .outputFeatureMissing(let have, let want):
            return "embedder CoreML model has no \"\(want)\" output (has: \(have.joined(separator: ", ")))"
        case .dimensionMismatch(let d):
            return "embedder descriptor declares dim \(d) — every v1 model must be 384 (fixed index schema)"
        }
    }
}

/// Download (one-time) + ANE-compile + build the OFFLINE text embedder. Throws if
/// the download or CoreML compile fails — the caller treats embedder-unavailable
/// as non-fatal for live transcription (only vault RAG is degraded), exactly like
/// the diarizer.
///
/// - Parameters:
///   - model: which curated model to load. Defaults to the multilingual e5 small
///     default (ADR-0032). v1 only ever passes the default; the param exists so
///     slice 4c (Settings) and the bge-small slot reuse this loader unchanged.
///   - progressOutput: stderr by default (keeps stdout clean for JSON piping),
///     same convention as ModelLoader/DiarizerLoader.
///   - onProgress: optional `@Sendable` off-thread sink the daemon forwards to the
///     UI over the WebSocket. Phases: `downloading_embedder` (with HubApi's
///     fraction) during the snapshot; `optimizing_embedder` (fraction nil — the
///     ANE compile exposes no progress) during compile, re-emitted on a ~1.5s
///     ticker so the UI shows an alive indeterminate state. fraction is never
///     fabricated for the compile (same rule as the speech/diarizer loaders).
func loadTextEmbedder(
    model: EmbedderModel = EmbedderModels.default,
    progressOutput: FileHandle = .standardError,
    onProgress: (@Sendable (_ phase: String, _ fraction: Double?, _ detail: String) -> Void)? = nil
) async throws -> LoadedEmbedder {
    guard model.dimensionIsValid else {
        throw EmbedderLoadError.dimensionMismatch(declared: model.dimension)
    }
    let start = Date()

    // Rule #2: pin swift-transformers' download root to Hark's models dir. With
    // `useOfflineMode` left at its default, the FIRST run downloads; later runs
    // see the snapshot already present and skip the network. The snapshot lands at
    //   <models>/models/<repo>/   (HubApi's repo-typed layout)
    let modelsRoot = try HarkPaths.modelsDir()
    let hub = HubApi(downloadBase: modelsRoot)

    // DEV / TEST / "bring your own local model files" override: if
    // HARK_EMBEDDER_LOCAL_DIR points at a folder holding the `.mlpackage` +
    // tokenizer JSONs, load from there with NO network (no HubApi snapshot). This
    // is how the on-device cross-lingual test runs before the CoreML artifact is
    // published to a HF repo, and a clean hook for a user supplying their own
    // local conversion. Production (env unset) downloads from `model.repo` as before.
    let modelDir: URL
    let downloadSeconds: Double
    if let localPath = ProcessInfo.processInfo.environment["HARK_EMBEDDER_LOCAL_DIR"],
       !localPath.isEmpty {
        modelDir = URL(fileURLWithPath: localPath, isDirectory: true)
        downloadSeconds = 0
        progressOutput.write(Data(
            "Text embedder \"\(model.id)\": loading from local dir \(localPath) (no download)\n".utf8))
    } else {
        let repo = Hub.Repo(id: model.repo)
        progressOutput.write(Data(
            "Loading text embedder \"\(model.id)\" (first run downloads CoreML + tokenizer, ~tens of MB)…\n".utf8))

        // ── Phase A — snapshot the repo (CoreML package + tokenizer files only). ─
        // The globs keep us from pulling the redundant pytorch/safetensors/onnx
        // weights that sit in the source repo — we only need the .mlpackage + the
        // tokenizer JSONs. (An owned conversion repo publishes only these anyway.)
        let downloadStart = Date()
        modelDir = try await hub.snapshot(
            from: repo,
            revision: model.revision,
            matching: ["\(model.mlpackageName)/*", "*.json", "*.model"],
            progressHandler: { progress in
                onProgress?("downloading_embedder", progress.fractionCompleted, "Preparing vault search")
            }
        )
        downloadSeconds = Date().timeIntervalSince(downloadStart)
    }

    let mlpackageURL = modelDir.appendingPathComponent(model.mlpackageName, isDirectory: true)
    guard FileManager.default.fileExists(atPath: mlpackageURL.path) else {
        throw EmbedderLoadError.mlpackageMissing(mlpackageURL)
    }

    // ── Phase B — compile to ANE + load + build the offline tokenizer. ───────────
    progressOutput.write(Data("Compiling embedder for Neural Engine…\n".utf8))
    let compileStart = Date()
    onProgress?("optimizing_embedder", nil, "Preparing vault search")
    let optimizingPulse: Task<Void, Never>? = onProgress.map { sink in
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                sink("optimizing_embedder", nil, "Preparing vault search")
            }
        }
    }

    let mlModel: MLModel
    let tokenizer: Tokenizer
    do {
        // `.mlpackage` must be compiled to `.mlmodelc` before loading. CoreML
        // caches the compiled artifact internally; we don't persist it ourselves
        // (kept simple for the spike — a later optimization can cache the
        // .mlmodelc under Hark's dir to skip recompiles).
        let compiledURL = try await MLModel.compileModel(at: mlpackageURL)
        let config = MLModelConfiguration()
        // ANE first (the whole point — ADR-0032 "ANE-fast"); CoreML falls back to
        // GPU/CPU per-op if a layer isn't ANE-eligible.
        config.computeUnits = .cpuAndNeuralEngine
        mlModel = try MLModel(contentsOf: compiledURL, configuration: config)

        // Offline tokenizer: the snapshot already wrote tokenizer.json +
        // tokenizer_config.json into `modelDir`, so `from(modelFolder:)` reads
        // them locally. We pass the SAME hub (offline root) so no fallback fetch
        // can escape to ~/Documents/huggingface.
        tokenizer = try await AutoTokenizer.from(modelFolder: modelDir, hubApi: hub)
    } catch {
        optimizingPulse?.cancel()
        throw error
    }
    optimizingPulse?.cancel()
    let compileSeconds = Date().timeIntervalSince(compileStart)

    // Fail loudly NOW (at load) if the artifact doesn't expose the token-level
    // output we pool over — better a startup error than silent mis-pooling later.
    let outputNames = Array(mlModel.modelDescription.outputDescriptionsByName.keys)
    let wantFeature = "last_hidden_state"
    guard outputNames.contains(wantFeature) else {
        throw EmbedderLoadError.outputFeatureMissing(have: outputNames, want: wantFeature)
    }

    let embedder = CoreMLTextEmbedder(
        model: model, mlModel: mlModel, tokenizer: tokenizer, hiddenStateFeature: wantFeature)

    let totalLoadSeconds = Date().timeIntervalSince(start)
    progressOutput.write(Data(String(
        format: "Text embedder \"%@\" ready in %.2fs (download %.2fs, compile %.2fs) — model at: %@\n",
        model.id, totalLoadSeconds, downloadSeconds, compileSeconds, modelDir.path
    ).utf8))

    return LoadedEmbedder(
        embedder: embedder,
        model: model,
        modelDir: modelDir,
        downloadSeconds: downloadSeconds,
        compileSeconds: compileSeconds,
        totalLoadSeconds: totalLoadSeconds
    )
}
