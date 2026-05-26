// swift-tools-version: 5.10
//
// SPM manifest. Think of this as `pom.xml` / `build.gradle` for Swift.
//
// Three targets:
//   - HarkCore   — internal library: shared model loader + progress UX.
//                  No product exported; only consumed by sibling targets.
//   - HarkBench  — Phase 0 RTF harness binary.
//   - HarkEngine — Phase 1 batch transcribe binary (`hark-engine`).
//
// Dependencies:
//   - argmax-oss-swift (WhisperKit) — pinned v1.0.0 (SemVer-compatible).
//   - swift-argument-parser — already resolved transitively via WhisperKit
//     (see Package.resolved). We declare it explicitly so HarkEngine can
//     `import ArgumentParser`; we DON'T add a new third-party dependency
//     surface, we surface an existing one.
//
// Platforms: macOS 13 — floor required by argmax-oss-swift v1.0.0.
import PackageDescription

let package = Package(
    name: "HarkEngine",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "hark-bench", targets: ["HarkBench"]),
        .executable(name: "hark-engine", targets: ["HarkEngine"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            from: "1.0.0"
        ),
        // ArgumentParser is already pulled in transitively by WhisperKit
        // (1.7.1 in Package.resolved). Declaring it here gives HarkEngine
        // a direct import; SwiftPM will resolve to the same pinned version.
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
        )
    ]
)
