// ModelLoader — shared two-phase WhisperKit load with user-visible progress.
//
// Phase A: download model files. WhisperKit.download exposes a Foundation
//          Progress callback — we render a bar.
// Phase B: prewarm + compile to ANE + load. No progress API exists, so we
//          fall back to a heartbeat ticker so the user never sits in silence
//          for >5s.
//
// Used by both hark-bench (Phase 0 RTF harness) and hark-engine (Phase 1
// batch transcribe). Same UX in both places by construction.

import Foundation
import WhisperKit

/// The Whisper turbo CoreML bundle from Argmax. v20240930 is OpenAI's turbo
/// release date; turbo = large-v3 with a 4-layer decoder (vs 32 layers),
/// ~6× faster decode for almost no accuracy loss.
public let DEFAULT_MODEL_NAME = "large-v3-v20240930_626MB"

/// Result of `loadWhisperKit`. Includes timing so callers (the bench) can
/// report cold-start latency.
public struct LoadedModel {
    public let pipe: WhisperKit
    public let modelName: String
    public let modelFolderURL: URL
    public let downloadSeconds: Double
    public let compileSeconds: Double
    public let totalLoadSeconds: Double
}

/// Two-phase load: download (with progress bar) → compile + load (with heartbeat).
///
/// - Parameters:
///   - modelName: WhisperKit variant string. Defaults to turbo large-v3.
///   - downloadBase: directory under which model files are stored. `nil` uses
///     WhisperKit's default (`~/Documents/huggingface/...`). Per CLAUDE.md
///     where-things-live: production should pass `~/Library/Application Support/Hark/`
///     but we keep the default here so first-time devs don't see two cached
///     copies of a 626 MB model.
///   - progressOutput: file handle for progress redraws. Stderr by default
///     so stdout stays clean for JSON piping (`hark-engine ... | jq .`).
///   - onProgress: optional, off-thread sink for structured load progress so a
///     caller (harkd) can forward it to the UI over the WebSocket. It runs
///     ALONGSIDE the stderr `ProgressRenderer`/heartbeat (a dev affordance we
///     keep), not instead of it. `@Sendable` because WhisperKit's download
///     callback fires on an unspecified queue and the compile ticker runs on a
///     detached Task — the caller is responsible for hopping into its own actor.
///     Phases emitted: `downloading_speech` (with fraction 0..1) during Phase A;
///     `optimizing_speech` (fraction nil — the ANE compile exposes no progress)
///     once at the start of Phase B and re-emitted every ~1.5s so the UI knows
///     it's alive. fraction stays nil for the compile — we do NOT fabricate one.
public func loadWhisperKit(
    modelName: String = DEFAULT_MODEL_NAME,
    downloadBase: URL? = nil,
    progressOutput: FileHandle = .standardError,
    onProgress: (@Sendable (_ phase: String, _ fraction: Double?, _ detail: String) -> Void)? = nil
) async throws -> LoadedModel {
    // Phase A — download.
    let renderer = ProgressRenderer(label: "Downloading model", output: progressOutput)
    progressOutput.write(Data("Downloading model (first run only, ~626 MB)...\n".utf8))
    let loadStart = Date()

    let modelFolderURL: URL
    do {
        modelFolderURL = try await WhisperKit.download(
            variant: modelName,
            downloadBase: downloadBase,
            progressCallback: { progress in
                renderer.update(progress)
                // Forward the same fraction to the structured sink. The caller
                // throttles before its actor hop; we pass every callback through.
                onProgress?("downloading_speech", progress.fractionCompleted, "Downloading speech model")
            }
        )
        renderer.finish()
    } catch {
        renderer.finish()
        throw error
    }
    let downloadSeconds = Date().timeIntervalSince(loadStart)
    progressOutput.write(Data(String(
        format: "Model files ready in %.1fs at: %@\n", downloadSeconds, modelFolderURL.path
    ).utf8))

    // Phase B — prewarm + Core ML compile + load.
    progressOutput.write(Data("\nCompiling for ANE and loading (10–30s typical on first run)...\n".utf8))
    let compileStart = Date()
    let heartbeat = startHeartbeat(label: "still loading", output: progressOutput)

    // Structured "optimizing" pulse for the UI. The ANE compile/specialize step
    // exposes NO progress fraction, so we emit `optimizing_speech` with a nil
    // fraction once now, then re-emit it on a ~1.5s ticker (mirroring the stderr
    // heartbeat pattern) so a progress bar can show an alive, indeterminate
    // state. fraction is ALWAYS nil here — never fabricated. Cancelled the
    // instant load returns (success or throw).
    onProgress?("optimizing_speech", nil, "Optimizing for Neural Engine")
    let optimizingPulse: Task<Void, Never>? = onProgress.map { sink in
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                sink("optimizing_speech", nil, "Optimizing for Neural Engine")
            }
        }
    }

    let pipe: WhisperKit
    do {
        // Pass `modelFolder` so WhisperKit skips its internal (no-progress)
        // download path and jumps straight to compile + load.
        pipe = try await WhisperKit(WhisperKitConfig(
            model: modelName,
            modelFolder: modelFolderURL.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        ))
    } catch {
        optimizingPulse?.cancel()
        heartbeat.cancel()
        throw error
    }
    optimizingPulse?.cancel()
    heartbeat.cancel()
    let compileSeconds = Date().timeIntervalSince(compileStart)
    let totalLoadSeconds = Date().timeIntervalSince(loadStart)
    progressOutput.write(Data(String(
        format: "Compile + load: %.2fs  (total: %.2fs)\n\n", compileSeconds, totalLoadSeconds
    ).utf8))

    return LoadedModel(
        pipe: pipe,
        modelName: modelName,
        modelFolderURL: modelFolderURL,
        downloadSeconds: downloadSeconds,
        compileSeconds: compileSeconds,
        totalLoadSeconds: totalLoadSeconds
    )
}
