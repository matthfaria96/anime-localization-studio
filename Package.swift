// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnimeLocalizationStudio",
    defaultLocalization: "pt-BR",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "AnimeLocalizationStudio", targets: ["AnimeLocalizationStudio"])
    ],
    dependencies: [
        // Speaker diarization on the Neural Engine (Apache-2.0; models CC-BY-4.0, downloaded on request).
        // `traits: []` drops the default NemoTextProcessing binary (ASR text normalization, not used here).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: [])
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
        .target(name: "DubbingKit", dependencies: ["SubtitleKit", "MediaKit", .product(name: "FluidAudio", package: "FluidAudio")]),
        // libass (ISC) through pkg-config; bundled into the app by Scripts/build-app.sh.
        .systemLibrary(name: "CLibass", pkgConfig: "libass", providers: [.brew(["libass"])]),
        // Faithful ASS rendering (animations, karaoke, drawings, embedded fonts) for the preview.
        .target(name: "ASSRendering", dependencies: ["CLibass"]),
        // Persistence, settings, secrets, job queue, log redaction.
        .target(name: "StudioCore", dependencies: ["SubtitleKit", "MediaKit", "TranslationKit", "DubbingKit"]),
        .executableTarget(
            name: "AnimeLocalizationStudio",
            dependencies: ["SubtitleKit", "MediaKit", "TranslationKit", "DubbingKit", "StudioCore", "ASSRendering"],
            resources: [.process("Resources")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "SubtitleKitTests", dependencies: ["SubtitleKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit", "SubtitleKit"]),
        .testTarget(name: "TranslationKitTests", dependencies: ["TranslationKit", "SubtitleKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "DubbingKitTests", dependencies: ["DubbingKit", "SubtitleKit", "MediaKit"]),
        .testTarget(name: "ASSRenderingTests", dependencies: ["ASSRendering"]),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore", "TranslationKit", "MediaKit", "SubtitleKit", "DubbingKit"])
    ]
)
