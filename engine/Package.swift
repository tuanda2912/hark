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
//
// Dependencies:
//   - argmax-oss-swift (WhisperKit) — pinned v1.0.0 (SemVer-compatible).
//   - swift-argument-parser — already resolved transitively via WhisperKit.
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
        .executable(name: "hark-capture", targets: ["HarkCapture"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
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
        .executableTarget(
            name: "HarkCapture",
            dependencies: [
                "HarkCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/HarkCapture",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "HarkCaptureTests",
            dependencies: ["HarkCore", "HarkCapture"],
            path: "Tests/HarkCaptureTests"
        )
    ]
)
