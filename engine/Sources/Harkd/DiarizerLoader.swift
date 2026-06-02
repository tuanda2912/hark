// DiarizerLoader — downloads + loads FluidAudio's OFFLINE diarization models
// into Hark's app-support models dir, then builds a ready
// `OfflineDiarizerManager`. Mirrors HarkCore.ModelLoader's two-phase
// (download-into-Hark-dir, then build) pattern for WhisperKit.
//
// Lives in the Harkd target (not HarkCore) because FluidAudio is a
// Harkd-only dependency — pulling it into HarkCore would link the CoreML
// diarizer into hark-bench / hark-engine / hark-capture, none of which
// diarize. The model-cache LOCATION is still shared via HarkCore.HarkPaths
// so there's one auditable answer to rule #2 ("where do caches live?").
//
// Phase 5 / ADR-0016: pyannote-community-1 segmentation + WeSpeaker embedding
// + PLDA CoreML bundles, ANE-resident. Download is one-time from HuggingFace
// (same in kind as WhisperKit's first-run fetch); after that, fully offline.
//
// Why OFFLINE (vs the streaming `DiarizerManager` slice 1 shipped): our use is
// a whole-recording batch pass at capture.stop, NOT live. FluidAudio's offline
// pipeline runs VBx GLOBAL clustering over OVERLAPPING segmentation windows and
// emits EXCLUSIVE (non-overlapping) speaker segments — ~10.6% vs ~26% DER on
// AMI, and far finer turn boundaries. Those finer/exclusive segments are what
// fix the rapid back-and-forth mislabeling the streaming chunked pass produced.
//
// CRITICAL (CLAUDE.md hard rule #2): models MUST cache under
// `~/Library/Application Support/Hark/Models/`, never FluidAudio's default
// `~/Library/Application Support/FluidAudio/Models/`. We achieve that by
// passing Hark's models root as `OfflineDiarizerModels.load(from:)` — the
// loader appends the repo's own folder name ("speaker-diarization-coreml") and
// lands everything inside Hark's dir (see note at the call site).

import Foundation
import FluidAudio
import HarkCore

/// Result of `loadDiarizerModels`. Carries timing so the daemon can log
/// cold-start cost the same way it does for WhisperKit.
struct LoadedDiarizer {
    let manager: OfflineDiarizerManager
    let modelsDir: URL
    let loadSeconds: Double
}

/// Build the `OfflineDiarizerConfig` from a SMALL set of `HARK_DIAR_*` env
/// vars, each defaulting to FluidAudio's offline `.default` (the pyannote
/// community-1 pipeline). Accuracy is meant to come from the pipeline, not from
/// us hand-tuning — so this exposes only the two levers that genuinely matter
/// for a 1:1 meeting and leaves the rest at the library's tuned defaults.
///
/// Default behavior is UNCHANGED when no env var is set: the config is exactly
/// `OfflineDiarizerConfig.default`.
///
/// Knobs (env → field → default → clamp range):
///   HARK_DIAR_THRESHOLD   → clustering.threshold  → 0.6  → (0, sqrt(2)]≈1.414
///       Speaker-COUNT lever. EUCLIDEAN distance threshold on unit-normalized
///       embeddings (NOT the streaming pipeline's cosine 0.7 — different scale).
///       Lower = more clusters (splits one talker into many); higher = fewer
///       (merges distinct talkers). The library validates (0, sqrt(2)]; we clamp
///       to that so an out-of-range sweep value never throws at diarize time.
///   HARK_DIAR_NUM_SPEAKERS → clustering.numSpeakers → nil (auto) → [1, 20]
///       Speaker-COUNT override. When set, forces EXACTLY this many speakers
///       (VBx constrained), bypassing the threshold's auto-estimate. Unset =
///       auto-detect (the default, anonymous-v1 behavior). This is the lever to
///       reach for when a known 2-speaker clip is over/under-split — set =2.
///
/// NOTE: min/maxSpeakers, the VBx Fa/Fb warm-start, segmentation step ratio,
/// embedding excludeOverlap, and exclusiveSegments are intentionally NOT exposed
/// — they're the community-1 tuned defaults and we don't fight them. numSpeakers
/// is the one count override worth a knob; threshold is the one continuous lever.
func makeDiarizerConfigFromEnv(progressOutput: FileHandle = .standardError) -> OfflineDiarizerConfig {
    let env = ProcessInfo.processInfo.environment
    var config = OfflineDiarizerConfig.default

    // Parse a Double env var, clamp to [lo, hi], fall back to `fallback` when
    // unset or unparseable. Logs a warning on an unparseable/clamped value so a
    // typo in a sweep doesn't silently use the default.
    func doubleEnv(_ key: String, fallback: Double, lo: Double, hi: Double) -> Double {
        guard let raw = env[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return fallback
        }
        guard let parsed = Double(raw) else {
            progressOutput.write(Data("harkd: \(key)=\"\(raw)\" not a number — using default \(fallback)\n".utf8))
            return fallback
        }
        let clamped = min(max(parsed, lo), hi)
        if clamped != parsed {
            progressOutput.write(Data(
                "harkd: \(key)=\(parsed) out of [\(lo), \(hi)] — clamped to \(clamped)\n".utf8))
        }
        return clamped
    }

    // Parse an optional Int env var (unset → nil → auto), clamped when present.
    func intEnvOptional(_ key: String, lo: Int, hi: Int) -> Int? {
        guard let raw = env[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        guard let parsed = Int(raw) else {
            progressOutput.write(Data("harkd: \(key)=\"\(raw)\" not an integer — ignoring (auto speaker count)\n".utf8))
            return nil
        }
        let clamped = min(max(parsed, lo), hi)
        if clamped != parsed {
            progressOutput.write(Data(
                "harkd: \(key)=\(parsed) out of [\(lo), \(hi)] — clamped to \(clamped)\n".utf8))
        }
        return clamped
    }

    // sqrt(2) is the library's documented upper bound for the Euclidean
    // threshold on unit-normalized embeddings (see OfflineDiarizerConfig.validate).
    let maxThreshold = 2.0.squareRoot()
    config.clustering.threshold = doubleEnv(
        "HARK_DIAR_THRESHOLD", fallback: config.clustering.threshold, lo: 0.1, hi: maxThreshold)

    let numSpeakers = intEnvOptional("HARK_DIAR_NUM_SPEAKERS", lo: 1, hi: 20)
    if let n = numSpeakers {
        // withSpeakers(exactly:) is the library's own helper — it sets
        // numSpeakers and clears min/max so VBx is constrained to exactly n.
        config = config.withSpeakers(exactly: n)
    }

    // One startup line so every sweep run records the exact config it used.
    func src(_ key: String) -> String { env[key]?.isEmpty == false ? "env" : "default" }
    progressOutput.write(Data(String(
        format: "harkd: offline-diarizer config — threshold=%.3f(%@) numSpeakers=%@(%@)  [stepRatio=%.2f excludeOverlap=%@ exclusiveSegments=%@ defaults]\n",
        config.clustering.threshold, src("HARK_DIAR_THRESHOLD"),
        numSpeakers.map { String($0) } ?? "auto", src("HARK_DIAR_NUM_SPEAKERS"),
        config.segmentation.stepRatio,
        config.embedding.excludeOverlap ? "true" : "false",
        config.postProcessing.exclusiveSegments ? "true" : "false"
    ).utf8))

    return config
}

/// Download (one-time) + load the FluidAudio OFFLINE diarizer models, then
/// build a ready `OfflineDiarizerManager`. Throws if the download or CoreML
/// compile fails — the caller treats diarizer-unavailable as non-fatal
/// (capture + live transcription still work; only the post-stop pass is
/// skipped).
///
/// - Parameters:
///   - config: diarization tuning. When `nil` (the default), the config is
///     built from `HARK_DIAR_*` env vars via `makeDiarizerConfigFromEnv`,
///     which itself defaults to FluidAudio's offline `.default` (the pyannote
///     community-1 pipeline) when no env var is set. v1 uses anonymous
///     "Speaker N" — within-meeting clustering only, no enrollment.
///   - progressOutput: stderr by default (keeps stdout clean), same as
///     ModelLoader.
///   - onProgress: optional, off-thread sink for structured load progress so the
///     daemon can forward it to the UI over the WebSocket. `@Sendable` because
///     FluidAudio fires its `ProgressHandler` on an unspecified queue — the
///     caller hops into its own actor. We map FluidAudio's `DownloadPhase`:
///     `.listing`/`.downloading` → `downloading_diarizer`, `.compiling` →
///     `optimizing_diarizer`, both carrying FluidAudio's `fractionCompleted`
///     (download 0..0.5, compile 0.5..1.0 — byte-continuous). Diarizer load is
///     NON-FATAL (readiness gates on WhisperKit only); a failure here never
///     reaches the UI as anything but the absence of further frames.
func loadDiarizerModels(
    config: OfflineDiarizerConfig? = nil,
    progressOutput: FileHandle = .standardError,
    onProgress: (@Sendable (_ phase: String, _ fraction: Double?, _ detail: String) -> Void)? = nil
) async throws -> LoadedDiarizer {
    let start = Date()
    let config = config ?? makeDiarizerConfigFromEnv(progressOutput: progressOutput)

    // `OfflineDiarizerModels.load(from:)` treats the passed URL as the models
    // ROOT and internally appends the diarizer repo's folder name
    // ("speaker-diarization-coreml"), landing files at
    //   ~/Library/Application Support/Hark/Models/speaker-diarization-coreml/
    // So we pass Hark's models root directly (NOT a pre-appended subfolder, as
    // the streaming `DiarizerModels.download(to:)` path required) — the library
    // builds the repo subdir for us, and the PLDA-parameters lookup also probes
    // that same subdir. Rule #2 holds: everything stays under Hark's dir.
    let harkModels = try HarkPaths.modelsDir()

    progressOutput.write(Data(
        "Loading OFFLINE diarizer models (first run downloads ~pyannote-community-1 + wespeaker CoreML bundles)…\n".utf8))

    let models = try await OfflineDiarizerModels.load(
        from: harkModels,
        progressHandler: onProgress.map { sink in
            { @Sendable (progress: DownloadUtils.DownloadProgress) in
                // One human label across both phases ("Preparing speaker
                // recognition") — the phase string is the machine-readable
                // distinction; FluidAudio's fraction is byte-continuous
                // (download 0..0.5, compile 0.5..1.0).
                switch progress.phase {
                case .listing, .downloading:
                    sink("downloading_diarizer", progress.fractionCompleted, "Preparing speaker recognition")
                case .compiling:
                    sink("optimizing_diarizer", progress.fractionCompleted, "Preparing speaker recognition")
                }
            }
        }
    )

    let manager = OfflineDiarizerManager(config: config)
    manager.initialize(models: models)

    let diarizerCacheDir = harkModels.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
    let loadSeconds = Date().timeIntervalSince(start)
    progressOutput.write(Data(String(
        format: "Offline diarizer ready in %.2fs — models at: %@\n",
        loadSeconds, diarizerCacheDir.path
    ).utf8))

    return LoadedDiarizer(manager: manager, modelsDir: diarizerCacheDir, loadSeconds: loadSeconds)
}
