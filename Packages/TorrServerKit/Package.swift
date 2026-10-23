// swift-tools-version:6.0
// TorrServer внутри приложения: готовая gomobile-сборка из релиза TorrServer (MatriX).
// Новая версия — поменять адрес и checksum (`shasum -a 256` архива).

import PackageDescription

let package = Package(
    name: "TorrServerKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "TorrServerEngine", targets: ["TorrServerEngine"]),
    ],
    targets: [
        .binaryTarget(
            name: "TorrServerKit",
            url: "https://github.com/YouROK/TorrServer/releases/download/MatriX.147.1/TorrServer-ios-TorrServerKit.xcframework.zip",
            checksum: "7a4b5400eda368deb1a120bc2edf05c0473d7b7a75a5cb7efdda516a615dace5"
        ),
        .target(
            name: "TorrServerEngine",
            dependencies: ["TorrServerKit"],
            path: "Sources/TorrServerEngine",
            linkerSettings: [
                // Рантайм Go: DNS (res_search), сертификаты и сеть системы.
                .linkedLibrary("resolv"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
