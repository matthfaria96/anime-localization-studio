// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnimeLocalizationStudio",
    defaultLocalization: "pt-BR",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "AnimeLocalizationStudio", targets: ["AnimeLocalizationStudio"])
    ],
    targets: [
        // Pure Swift: ASS/SSA/SRT parsing, preservation-first serialization, override tags, timing.
        .target(name: "SubtitleKit"),
        // External tools (MKVToolNix, FFmpeg): discovery, subprocesses, inspection, extraction,
        // muxing without re-encoding, integrity checks and preview proxies.
        .target(name: "MediaKit"),
        // Translation engines, glossary, batched contextual pipeline with checkpoints.
        .target(name: "TranslationKit", dependencies: ["SubtitleKit"]),
        // VoiceStudio adapter (local HTTP), voice casting and dubbing plans.
        .target(name: "DubbingKit", dependencies: ["SubtitleKit", "MediaKit"]),
        // Persistence, settings, secrets, job queue, log redaction.
        .target(name: "StudioCore", dependencies: ["SubtitleKit", "MediaKit", "TranslationKit", "DubbingKit"]),
        .executableTarget(
            name: "AnimeLocalizationStudio",
            dependencies: ["SubtitleKit", "MediaKit", "TranslationKit", "DubbingKit", "StudioCore"],
            resources: [.process("Resources")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "SubtitleKitTests", dependencies: ["SubtitleKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit", "SubtitleKit"]),
        .testTarget(name: "TranslationKitTests", dependencies: ["TranslationKit", "SubtitleKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "DubbingKitTests", dependencies: ["DubbingKit", "SubtitleKit", "MediaKit"]),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore", "TranslationKit", "MediaKit", "SubtitleKit", "DubbingKit"])
    ]
)
