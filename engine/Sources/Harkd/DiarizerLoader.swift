// DiarizerLoader — downloads + loads FluidAudio's offline diarization models
// into Hark's app-support models dir, mirroring HarkCore.ModelLoader's
// two-phase pattern for WhisperKit.
//
// Lives in the Harkd target (not HarkCore) because FluidAudio is a
// Harkd-only dependency — pulling it into HarkCore would link the CoreML
// diarizer into hark-bench / hark-engine / hark-capture, none of which
// diarize. The model-cache LOCATION is still shared via HarkCore.HarkPaths
// so there's one auditable answer to rule #2 ("where do caches live?").
//
// Phase 5 / ADR-0016: pyannote segmentation + 256-dim WeSpeaker embedding
// CoreML bundles, ANE-resident. Download is one-time from HuggingFace (same
// in kind as WhisperKit's first-run fetch); after that, fully offline.
//
// CRITICAL (CLAUDE.md hard rule #2): models MUST cache under
// `~/Library/Application Support/Hark/Models/`, never FluidAudio's default
// `~/Library/Application Support/FluidAudio/Models/`. We achieve that by
// passing `to:` a Hark-rooted directory whose layout mirrors FluidAudio's
// own `defaultModelsDirectory(for:.diarizer)` (see note below).

import Foundation
import FluidAudio
import HarkCore

/// Result of `loadDiarizerModels`. Carries timing so the daemon can log
/// cold-start cost the same way it does for WhisperKit.
struct LoadedDiarizer {
    let manager: DiarizerManager
    let modelsDir: URL
    let loadSeconds: Double
}

/// Download (one-time) + load the FluidAudio diarizer models, then build a
/// ready `DiarizerManager`. Throws if the download or CoreML compile fails —
/// the caller treats diarizer-unavailable as non-fatal (capture still works).
///
/// - Parameters:
///   - config: diarization tuning. Default is FluidAudio's `.default`
///     (clusteringThreshold 0.7, auto speaker count). v1 uses anonymous
///     "Speaker N" — within-meeting clustering only, no enrollment.
///   - progressOutput: stderr by default (keeps stdout clean), same as
///     ModelLoader.
func loadDiarizerModels(
    config: DiarizerConfig = .default,
    progressOutput: FileHandle = .standardError
) async throws -> LoadedDiarizer {
    let start = Date()

    // FluidAudio's `DiarizerModels.download(to:)` internally does
    // `to.deletingLastPathComponent()` and then re-appends the repo's
    // folder name ("speaker-diarization"). So to land files at
    //   ~/Library/Application Support/Hark/Models/speaker-diarization/
    // we pass exactly that path as `to:` — mirroring FluidAudio's own
    // `defaultModelsDirectory(for:.diarizer)` shape but rooted in Hark's dir.
    let harkModels = try HarkPaths.modelsDir()
    let diarizerCacheDir = harkModels.appendingPathComponent("speaker-diarization", isDirectory: true)

    progressOutput.write(Data(
        "Loading diarizer models (first run downloads ~pyannote+wespeaker CoreML bundles)…\n".utf8))

    let models = try await DiarizerModels.download(to: diarizerCacheDir)

    let manager = DiarizerManager(config: config)
    manager.initialize(models: models)

    let loadSeconds = Date().timeIntervalSince(start)
    progressOutput.write(Data(String(
        format: "Diarizer ready in %.2fs — models at: %@\n",
        loadSeconds, diarizerCacheDir.path
    ).utf8))

    return LoadedDiarizer(manager: manager, modelsDir: diarizerCacheDir, loadSeconds: loadSeconds)
}
