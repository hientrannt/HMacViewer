// swift-tools-version: 6.0
import Foundation
import PackageDescription

// CI sets MACVIEWER_MIN_MACOS=11 for the experimental Big Sur build.
let minimumMacOS: SupportedPlatform = ProcessInfo.processInfo.environment["MACVIEWER_MIN_MACOS"] == "11"
    ? .macOS(.v11) : .macOS(.v12)

// scripts/build_remotecore.sh builds VNC/RDP support (RemoteCore, Rust); without
// it RemoteCoreKit compiles with VNC/RDP reported as unavailable.
let remoteCoreFramework = "RemoteCore/build/RemoteCoreFFI.xcframework"
let hasRemoteCore = FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent(remoteCoreFramework).path)
let remoteCoreDependencies: [Target.Dependency] = hasRemoteCore ? ["RemoteCoreFFI"] : []

let package = Package(
    name: "MacViewer",
    defaultLocalization: "en",
    platforms: [minimumMacOS, .iOS(.v16)],
    products: [
        .library(name: "UltraViewerProtocol", targets: ["UltraViewerProtocol"]),
        .library(name: "RemoteCoreKit", targets: ["RemoteCoreKit"]),
        .executable(name: "MacViewer", targets: ["MacViewer"]),
        .executable(name: "macviewer-mcp", targets: ["macviewer-mcp"]),
    ],
    targets: [
        .target(
            name: "CG722",
            path: "ThirdParty/g722",
            exclude: ["LICENSE", "WEBRTC_LICENSE", "provenance.json", "g722_enc_dec.h"],
            sources: ["g722_decode.c", "MacViewerG722.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
        ),
        .target(
            name: "CZstd",
            path: "ThirdParty/zstd",
            sources: [
                "lib/common/debug.c", "lib/common/entropy_common.c",
                "lib/common/error_private.c", "lib/common/fse_decompress.c",
                "lib/common/pool.c", "lib/common/threading.c",
                "lib/common/xxhash.c", "lib/common/zstd_common.c",
                "lib/compress/fse_compress.c", "lib/compress/hist.c",
                "lib/compress/huf_compress.c", "lib/compress/zstd_compress.c",
                "lib/compress/zstd_compress_literals.c", "lib/compress/zstd_compress_sequences.c",
                "lib/compress/zstd_compress_superblock.c", "lib/compress/zstd_double_fast.c",
                "lib/compress/zstd_fast.c", "lib/compress/zstd_lazy.c",
                "lib/compress/zstd_ldm.c", "lib/compress/zstd_opt.c",
                "lib/compress/zstd_preSplit.c", "lib/compress/zstdmt_compress.c",
                "lib/decompress/huf_decompress.c", "lib/decompress/zstd_ddict.c",
                "lib/decompress/zstd_decompress.c", "lib/decompress/zstd_decompress_block.c",
                "lib/legacy/zstd_v04.c", "lib/legacy/zstd_v05.c",
                "lib/legacy/zstd_v06.c", "lib/legacy/zstd_v07.c",
            ],
            publicHeadersPath: "include",
            cSettings: [.define("ZSTD_LEGACY_SUPPORT", to: "4"), .define("ZSTD_DISABLE_ASM", to: "1")]
        ),
        .target(name: "UltraViewerProtocol", dependencies: ["CZstd", "CG722"],
                resources: [.copy("Resources/8bit.dat")]),
        .target(name: "RemoteCoreKit", dependencies: remoteCoreDependencies,
                linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("Security"),
                                 .linkedFramework("SystemConfiguration"), .linkedLibrary("z")]),
        .executableTarget(name: "MacViewer", dependencies: ["UltraViewerProtocol", "RemoteCoreKit"],
                          resources: [.process("Resources")]),
        .executableTarget(name: "macviewer-mcp", path: "Sources/MacViewerMCP"),
        .testTarget(name: "UltraViewerProtocolTests", dependencies: ["UltraViewerProtocol"]),
        .testTarget(name: "MacViewerTests", dependencies: ["MacViewer"]),
    ]
)

if hasRemoteCore {
    package.targets.append(.binaryTarget(name: "RemoteCoreFFI", path: remoteCoreFramework))
}
