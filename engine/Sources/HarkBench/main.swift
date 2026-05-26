// HarkBench — Phase 0 RTF (Real-Time Factor) harness.
//
// Goal: prove that WhisperKit large-v3-turbo on Apple Neural Engine can
// transcribe meeting-grade audio at RTF < 0.5 on the developer's actual Mac.
// If it can't, the entire stack assumption from ADR-0003 collapses.
//
// What this file is NOT:
// - A production engine. No streaming, no capture, no IPC.
// - A WER measurement. We only measure speed here.
// - A "real" benchmark suite. Single audio file in, single JSON out.
//
// ──────────────────────────────────────────────────────────────────────────
// Swift idioms cheat-sheet for a Java/Spring developer:
//
//   `import X`                ≈ Java `import x.*` (whole module)
//   `let`                     ≈ Java `final var` (immutable binding)
//   `var`                     ≈ Java `var` / mutable field
//   `async` / `await`         ≈ Kotlin coroutines / Java Loom virtual threads.
//                              The function suspends, it does NOT block a
//                              kernel thread. Color (async↔sync) is enforced
//                              by the compiler.
//   `try` / `throws`          ≈ Java checked exceptions, but the syntax marks
//                              EACH call site (`try foo()`) so the throw
//                              point is visible. `try?` swallows to nil,
//                              `try!` crashes on failure (like `.get()` on
//                              Optional in Java — avoid in production).
//   `Optional<T>` / `T?`      ≈ Java Optional<T>, but built into the type
//                              system (no `Optional.empty()` boilerplate).
//   `struct`                  ≈ Java record (value semantics, copied on
//                              assignment). Default in Swift for data.
//   `class`                   ≈ Java class (reference semantics, on the heap).
//                              Used here only because WhisperKit hands us one.
//   `Codable`                 ≈ Jackson `@JsonSerializable` on steroids. The
//                              compiler synthesises encode/decode for free.
//   `@main`                   ≈ `public static void main(String[] args)`,
//                              but applied to a type whose `main()` is the
//                              entry point. We use top-level code here
//                              instead — main.swift is special-cased by the
//                              compiler to be the entry point directly.
// ──────────────────────────────────────────────────────────────────────────

import Foundation       // FileManager, JSONEncoder, Date, URL — the std lib
import WhisperKit       // The ASR pipeline (argmax-oss-swift)
import HarkCore         // Shared load + progress logic (also used by hark-engine)

#if canImport(Darwin)
import Darwin           // For uname() — chip identification on macOS
#endif

// MARK: - Tunables (production settings per docs/qa/10-performance-benchmarks.md)

/// 30-second analysis window matches the production sliding-window setting.
let WINDOW_SECONDS: Double = 30.0

/// 5-second hop — windows overlap by 25s. This is the production setting; it
/// is intentionally aggressive (we re-transcribe overlap for stability) and
/// it is the worst case for RTF, which is exactly what we want to measure.
let HOP_SECONDS: Double = 5.0

/// Whisper expects 16 kHz mono. AudioProcessor.loadAudioAsFloatArray
/// resamples for us, but the math below depends on this constant.
let SAMPLE_RATE: Int = 16_000

/// The model we ship in production. Defined in HarkCore so both binaries
/// agree on the canonical variant string.
let MODEL_NAME: String = DEFAULT_MODEL_NAME

/// Pass criterion from the perf benchmarks doc.
let RTF_PASS_THRESHOLD: Double = 0.5

// MARK: - JSON output schema
//
// `Codable` is the Swift Codable protocol — the compiler auto-generates
// JSON encode/decode for any struct whose fields are themselves Codable.
// Snake_case keys are produced by setting `keyEncodingStrategy` on the
// encoder below, so we keep camelCase property names here (Swift idiom).

struct HardwareInfo: Codable {
    let chip: String
    let ramGB: Int
    let osVersion: String
    let thermalStateStart: String
}

struct CaseResult: Codable {
    let name: String
    let windows: Int
    let rtfAvg: Double
    let rtfP50: Double
    let rtfP95: Double
    let rtfP99: Double
    let coldStartSeconds: Double
}

struct BenchReport: Codable {
    let hardware: HardwareInfo
    let model: String
    let runDate: String          // ISO-8601
    let inputFile: String
    let audioDurationSeconds: Double
    let cases: [CaseResult]
    let verdict: String          // "PASS" | "FAIL"
}

// MARK: - Hardware introspection
//
// No analytics. This block runs locally, prints locally, and is written only
// to the local Results/ folder. Per CLAUDE.md hard rule #3 — no telemetry.

func detectChip() -> String {
    // `sysctl -n machdep.cpu.brand_string` is the canonical way to get the
    // chip name on macOS. We shell out because the C API is fiddlier than
    // it's worth for a one-line bench tool.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
    task.arguments = ["-n", "machdep.cpu.brand_string"]
    let pipe = Pipe()
    task.standardOutput = pipe
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    } catch {
        return "unknown"
    }
}

func detectRamGB() -> Int {
    // ProcessInfo.processInfo is the equivalent of Java's
    // ManagementFactory.getOperatingSystemMXBean() for trivial stats.
    let bytes = ProcessInfo.processInfo.physicalMemory
    return Int(bytes / 1_073_741_824)  // bytes → GiB
}

func detectOSVersion() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

func detectThermalState() -> String {
    // `.nominal` = cool, `.fair` = warm, `.serious` = hot, `.critical` = throttling.
    // Phase 0 should start at .nominal — if not, the RTF reading is suspect.
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:  return "nominal"
    case .fair:     return "fair"
    case .serious:  return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

// MARK: - Stats helpers

/// Percentile via linear interpolation. Small N here (a 60s file with 5s hop
/// gives ~13 windows), so an off-the-shelf stats library is overkill.
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = p * Double(sorted.count - 1)
    let lower = Int(rank.rounded(.down))
    let upper = Int(rank.rounded(.up))
    if lower == upper { return sorted[lower] }
    let weight = rank - Double(lower)
    return sorted[lower] * (1 - weight) + sorted[upper] * weight
}

func gitShortSha() -> String {
    // We're in a git repo (per the task description), but no commits yet.
    // Try anyway; fall back to "nogit" if HEAD doesn't exist.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["git", "-C",
                      URL(fileURLWithPath: #filePath).deletingLastPathComponent().path,
                      "rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()  // swallow "fatal: ..." on empty repo
    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 { return "nogit" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let sha = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (sha?.isEmpty == false) ? sha! : "nogit"
    } catch {
        return "nogit"
    }
}

// MARK: - Main
//
// Top-level code in `main.swift` is the program entry point. Swift wraps
// the file in an implicit `@main` for us, so we can `await` here directly.
// (In a non-main.swift file we'd need `@main struct App { static func main() ... }`.)

// argv[0] is the binary path; argv[1] is the user's first argument.
guard CommandLine.arguments.count >= 2 else {
    print("Usage: hark-bench <path-to-audio.wav>")
    print("  Audio: any format AudioProcessor accepts (.wav .mp3 .m4a .flac).")
    print("         Will be resampled to 16 kHz mono internally.")
    exit(64)  // EX_USAGE
}

let inputPath = CommandLine.arguments[1]
guard FileManager.default.fileExists(atPath: inputPath) else {
    print("error: file not found: \(inputPath)")
    exit(66)  // EX_NOINPUT
}

print("──────────────────────────────────────────────────────────────")
print("Hark Phase 0 — RTF benchmark")
print("──────────────────────────────────────────────────────────────")

let hw = HardwareInfo(
    chip: detectChip(),
    ramGB: detectRamGB(),
    osVersion: detectOSVersion(),
    thermalStateStart: detectThermalState()
)
print("Hardware:       \(hw.chip), \(hw.ramGB) GB, \(hw.osVersion)")
print("Thermal state:  \(hw.thermalStateStart)")
print("Model:          \(MODEL_NAME)")
print("Input:          \(inputPath)")
print("Window / hop:   \(Int(WINDOW_SECONDS))s / \(Int(HOP_SECONDS))s")
print("")

// ─── Load WhisperKit ───
//
// `try await` = "this can throw AND suspend".
// First run downloads ~626 MB of CoreML weights from HuggingFace into
// ~/Documents/huggingface/models/argmaxinc/... — this is the only sanctioned
// network call in the whole binary (see ADR-0003 + README).
//
// We split load into two phases so the user gets real feedback:
//   Phase A — download: WhisperKit.download(...) exposes a Foundation
//             `Progress` via a ProgressCallback. We render a text bar.
//   Phase B — prewarm + compile + load: no progress API exists for the
//             Core ML compile step, so we print an elapsed-time heartbeat.
//
// Model load — delegated to HarkCore so hark-engine uses the exact same
// progress UX. We route progress to stdout here (Phase 0 prints everything
// to stdout; only the Phase 1 engine needs the stdout/stderr split for
// pipe-into-jq cleanliness).
let loaded: LoadedModel
do {
    loaded = try await loadWhisperKit(
        modelName: MODEL_NAME,
        downloadBase: nil,
        progressOutput: .standardOutput
    )
} catch {
    print("error: failed to load WhisperKit: \(error)")
    exit(1)
}
let pipe = loaded.pipe
let loadSeconds = loaded.totalLoadSeconds

// ─── Load audio into Float samples ───
//
// AudioProcessor.loadAudioAsFloatArray returns Float at 16 kHz mono regardless
// of source format (it uses AVAudioConverter under the hood). Returns [] on
// failure rather than throwing — guard against that.
print("Loading audio...")
let samples: [Float]
do {
    // `try` marks the call site as a throw point — same idea as Java
    // checked exceptions, but visible at every call rather than only in
    // the method signature.
    samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: inputPath)
} catch {
    print("error: failed to decode audio at \(inputPath): \(error)")
    exit(1)
}
guard !samples.isEmpty else {
    print("error: decoded zero samples from \(inputPath)")
    exit(1)
}
let audioSeconds = Double(samples.count) / Double(SAMPLE_RATE)
print(String(format: "Loaded %d samples (%.2fs of audio at %d Hz)",
             samples.count, audioSeconds, SAMPLE_RATE))
print("")

// ─── Slide a 30s window with 5s hop ───
//
// For a 60s file with 30s window and 5s hop we expect 7 windows:
//   starts at 0, 5, 10, 15, 20, 25, 30 — last window ends at 60s.
// We DON'T pad short tail windows — if the file isn't long enough for one
// full window we use the whole file and report a single measurement.
let windowSamples = Int(WINDOW_SECONDS * Double(SAMPLE_RATE))
let hopSamples = Int(HOP_SECONDS * Double(SAMPLE_RATE))

var windows: [[Float]] = []
if samples.count <= windowSamples {
    windows.append(samples)
} else {
    var start = 0
    while start + windowSamples <= samples.count {
        // Array slicing in Swift: `samples[start..<end]` returns ArraySlice,
        // we re-wrap in Array() to detach from the parent storage.
        windows.append(Array(samples[start..<(start + windowSamples)]))
        start += hopSamples
    }
}
print("Will transcribe \(windows.count) window(s).")
print("")

// ─── Run transcription, measure wall clock per window ───
//
// `Date().timeIntervalSince(start)` is wall clock in seconds (Double).
// CFAbsoluteTimeGetCurrent() would be slightly more precise but Date is
// fine for window-level (>1s) measurements.
//
// RTF = wall_clock / audio_duration. RTF=0.5 means "1s of audio took
// 0.5s to transcribe" — i.e., 2× faster than real time.

var rtfs: [Double] = []
var coldStart: Double = 0

for (i, window) in windows.enumerated() {
    let windowAudioSec = Double(window.count) / Double(SAMPLE_RATE)
    let t0 = Date()
    do {
        // transcribe(audioArray:) returns [TranscriptionResult] (one per
        // detected segment-batch). We discard the text — this is a speed
        // benchmark, not a WER benchmark.
        _ = try await pipe.transcribe(audioArray: window)
    } catch {
        print("  window \(i): error \(error) — skipping")
        continue
    }
    let elapsed = Date().timeIntervalSince(t0)
    let rtf = elapsed / windowAudioSec
    rtfs.append(rtf)
    if i == 0 { coldStart = elapsed }
    print(String(format: "  window %2d/%d  audio=%.1fs  wall=%.2fs  rtf=%.3f%@",
                 i + 1, windows.count, windowAudioSec, elapsed, rtf,
                 i == 0 ? "   (cold)" : ""))
}

guard !rtfs.isEmpty else {
    print("error: no successful windows")
    exit(1)
}

// ─── Stats ───
//
// Question worth raising in review: should cold-start be excluded from
// rtf_avg? Production will only pay cold start once, so it skews the
// average for a short benchmark. We keep it in for honesty but report
// coldStartSeconds separately so the reader can subtract if they want.

let avg = rtfs.reduce(0, +) / Double(rtfs.count)
let p50 = percentile(rtfs, 0.50)
let p95 = percentile(rtfs, 0.95)
let p99 = percentile(rtfs, 0.99)

let caseResult = CaseResult(
    name: URL(fileURLWithPath: inputPath).lastPathComponent,
    windows: rtfs.count,
    rtfAvg: avg,
    rtfP50: p50,
    rtfP95: p95,
    rtfP99: p99,
    coldStartSeconds: coldStart
)

let verdict = (avg < RTF_PASS_THRESHOLD) ? "PASS" : "FAIL"

let report = BenchReport(
    hardware: hw,
    model: MODEL_NAME,
    runDate: ISO8601DateFormatter().string(from: Date()),
    inputFile: inputPath,
    audioDurationSeconds: audioSeconds,
    cases: [caseResult],
    verdict: verdict
)

// ─── Emit JSON to stdout and to Results/ ───

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
// Convert camelCase property names → snake_case JSON keys to match the
// schema example in the perf benchmark doc (rtf_avg, rtf_p95, ...).
encoder.keyEncodingStrategy = .convertToSnakeCase

let jsonData: Data
do {
    jsonData = try encoder.encode(report)
} catch {
    print("error: failed to encode report: \(error)")
    exit(1)
}

print("")
print("──────────────────────────────────────────────────────────────")
print("Report")
print("──────────────────────────────────────────────────────────────")
if let s = String(data: jsonData, encoding: .utf8) {
    print(s)
}

// Save under engine/Results/<ISO-date>-<git-sha-or-nogit>.json
// `#filePath` is a compile-time literal for the current source file's path —
// useful for finding the repo root reliably regardless of cwd.
let engineRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()    // HarkBench/
    .deletingLastPathComponent()    // Sources/
    .deletingLastPathComponent()    // engine/

let resultsDir = engineRoot.appendingPathComponent("Results", isDirectory: true)
try? FileManager.default.createDirectory(at: resultsDir,
                                         withIntermediateDirectories: true)

let dateStamp: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HHmmss"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: Date())
}()
let outName = "\(dateStamp)-\(gitShortSha()).json"
let outURL = resultsDir.appendingPathComponent(outName)

do {
    try jsonData.write(to: outURL, options: .atomic)
    print("")
    print("Saved: \(outURL.path)")
} catch {
    print("warn: failed to save report to \(outURL.path): \(error)")
}

// ─── Verdict ───
print("")
print("──────────────────────────────────────────────────────────────")
if verdict == "PASS" {
    print(String(format: "PASS  RTF avg=%.3f < %.2f  (p95=%.3f, cold=%.2fs)",
                 avg, RTF_PASS_THRESHOLD, p95, coldStart))
    print("──────────────────────────────────────────────────────────────")
    exit(0)
} else {
    print(String(format: "FAIL  RTF avg=%.3f >= %.2f  (p95=%.3f, cold=%.2fs)",
                 avg, RTF_PASS_THRESHOLD, p95, coldStart))
    print("Stack assumption from ADR-0003 needs revisiting.")
    print("──────────────────────────────────────────────────────────────")
    exit(2)
}
