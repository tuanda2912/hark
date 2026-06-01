// swift-tools-version: 5.10
//
// SPM manifest. Think of this as `pom.xml` / `build.gradle` for Swift.
//
// Targets:
//   - HarkCore    — internal library: shared model loader, progress UX,
//                   WAV writer.
//   - HarkBench   — Phase 0 RTF harness binary.
//   - HarkEngine  — Phase 1 batch transcribe binary (`hark-engine`).
//   - HarkCapture — Phase 2 audio capture binary (`hark-capture`):
//                   ScreenCaptureKit/Core Audio + AVAudioEngine → WAV.
//   - Harkd       — Phase 3 streaming engine daemon (`harkd`): capture
//                   in-process, VAD-gate, sliding-window WhisperKit,
//                   localhost WebSocket server (Swift NIO).
//
// Dependencies:
//   - argmax-oss-swift (WhisperKit) — pinned v1.0.0 (SemVer-compatible).
//   - swift-argument-parser — already resolved transitively via WhisperKit.
//   - swift-nio — WebSocket server (Phase 3, ADR-0008 §1).
//
// Platforms: macOS 14 — bumped from 13 in Phase 2 (ADR-0006) to enable
// Core Audio Process Taps for system-audio capture. The 14.4 minor floor
// the API actually requires is enforced with `@available` at the call site,
// since SPM platform pins only accept major versions.
import PackageDescription

let package = Package(
    name: "HarkEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "hark-bench", targets: ["HarkBench"]),
        .executable(name: "hark-engine", targets: ["HarkEngine"]),
        .executable(name: "hark-capture", targets: ["HarkCaptureCLI"]),
        .executable(name: "harkd", targets: ["Harkd"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
        // Swift NIO for the localhost WebSocket server (ADR-0008 §1).
        // Apple-maintained, semver. NIOPosix + NIOHTTP1 + NIOWebSocket
        // is the minimum surface for a single-endpoint loopback server.
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.65.0"
        ),
        // FluidAudio — pyannote-on-ANE offline speaker diarization (Phase 5).
        // PINNED to an exact tag (not a range) because the API iterates fast;
        // we code against the resolved checkout, not a moving target.
        // CoreML models download once into Hark's app-support dir (hard rule
        // #2). No network beyond that one-time fetch. (ADR pending.)
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.14.8"
        )
    ],
    targets: [
        .target(
            name: "HarkCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/HarkCore"
        ),
        .executableTarget(
            name: "HarkBench",
            dependencies: [
                "HarkCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/HarkBench"
        ),
        .executableTarget(
            name: "HarkEngine",
            dependencies: [
                "HarkCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/HarkEngine"
        ),
        // HarkCapture is now a library (Phase 3): both the standalone
        // `hark-capture` CLI and the `harkd` daemon link against it.
        .target(
            name: "HarkCapture",
            dependencies: [
                "HarkCore"
            ],
            path: "Sources/HarkCapture",
            exclude: ["README.md"]
        ),
        // Thin executable that drives the HarkCapture library — preserves
        // the `hark-capture` binary as a batch-test path (per ADR-0008 §2).
        .executableTarget(
            name: "HarkCaptureCLI",
            dependencies: [
                "HarkCore",
                "HarkCapture",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/HarkCaptureCLI"
        ),
        .executableTarget(
            name: "Harkd",
            dependencies: [
                "HarkCore",
                "HarkCapture",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Harkd"
        ),
        .testTarget(
            name: "HarkCaptureTests",
            dependencies: ["HarkCore", "HarkCapture"],
            path: "Tests/HarkCaptureTests"
        ),
        // Tests for the `Harkd` executable target's internal types.
        // `@testable import Harkd` works because SPM allows test targets
        // to depend on executable targets and import their module.
        .testTarget(
            name: "HarkdTests",
            dependencies: ["Harkd"],
            path: "Tests/HarkdTests"
        )
    ]
)
