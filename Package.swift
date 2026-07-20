// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LinkOSC",
    platforms: [.macOS(.v13)],
    targets: [
        // Ableton Link + Link Audio 公式 C ラッパー (header-only SDK + abl_link.cpp)
        .target(
            name: "CAblLink",
            path: "vendor/link/extensions/abl_link",
            sources: ["src/abl_link.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../include"),
                .headerSearchPath("../../modules/asio-standalone/asio/include"),
                .define("LINK_PLATFORM_MACOSX", to: "1"),
            ]
        ),
        .executableTarget(
            name: "LinkOSC",
            dependencies: ["CAblLink"],
            path: "Sources/LinkOSC",
            resources: [
                .copy("Resources/loop-test.wav"),
                .copy("Resources/loop-test-effects.wav"),
                .copy("Resources/loop-test.mid"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
