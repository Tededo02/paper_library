// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaperLibrary",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PaperLibrarySupport", targets: ["PaperLibrarySupport"]),
        .library(name: "PaperLibraryCore", targets: ["PaperLibraryCore"]),
        .library(name: "PaperLibraryUI", targets: ["PaperLibraryUI"]),
        .executable(name: "PaperLibrary", targets: ["PaperLibrary"])
    ],
    targets: [
        .target(name: "PaperLibrarySupport", path: "PaperLibrary/Support", resources: [.process("Resources")]),
        .target(name: "PaperLibraryCore", dependencies: ["PaperLibrarySupport"], path: "PaperLibrary/Core"),
        .target(name: "PaperLibraryUI", dependencies: ["PaperLibraryCore", "PaperLibrarySupport"], path: "PaperLibrary/UI"),
        .executableTarget(
            name: "PaperLibrary", dependencies: ["PaperLibraryCore", "PaperLibrarySupport", "PaperLibraryUI"],
            path: "PaperLibrary", exclude: ["Core", "Support", "UI", "Info.plist", "Resources"], sources: ["App", "Features"]
        ),
        .executableTarget(name: "StorageChecks", dependencies: ["PaperLibrarySupport"], path: "Verification/StorageChecks"),
        .executableTarget(name: "ArxivLiveCheck", dependencies: ["PaperLibraryCore", "PaperLibrarySupport"], path: "Verification/ArxivLiveCheck"),
        .executableTarget(name: "DOILiveCheck", dependencies: ["PaperLibraryCore", "PaperLibrarySupport"], path: "Verification/DOILiveCheck"),
        .executableTarget(name: "PDFLiveCheck", dependencies: ["PaperLibraryCore", "PaperLibrarySupport"], path: "Verification/PDFLiveCheck"),
        .executableTarget(name: "AILiveCheck", dependencies: ["PaperLibraryCore", "PaperLibrarySupport"], path: "Verification/AILiveCheck"),
        .testTarget(name: "PaperLibraryTests", dependencies: ["PaperLibraryCore", "PaperLibrarySupport", "PaperLibraryUI"], path: "PaperLibraryTests")
    ],
    swiftLanguageModes: [.v6]
)
