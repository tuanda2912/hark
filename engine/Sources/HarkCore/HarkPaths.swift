// HarkPaths — canonical on-disk locations for Hark's rebuildable app data.
//
// CLAUDE.md hard rule #2: model caches + app data live ONLY under
// `~/Library/Application Support/Hark/`. This is the one place that resolves
// that base, so every model loader (WhisperKit today, FluidAudio diarizer
// now) points at the same sanctioned directory instead of each dependency's
// own default (WhisperKit → ~/Documents/huggingface, FluidAudio →
// ~/Library/Application Support/FluidAudio). Keeping it here means there is a
// single auditable answer to "where does Hark write caches?".

import Foundation

public enum HarkPaths {
    /// `~/Library/Application Support/Hark/`. Created if missing.
    public static func appSupportDir() throws -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Hark", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/Hark/Models/`. Created if missing.
    /// CoreML model bundles (Whisper, diarizer) cache under here.
    public static func modelsDir() throws -> URL {
        let dir = try appSupportDir().appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
