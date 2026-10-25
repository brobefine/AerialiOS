// swift-tools-version:6.0
// TorrServer внутри приложения: gomobile-сборка релиза TorrServer (MatriX) с правками Aerial (`patches/`) — собирает
// задача CI `torrserverkit` и кладёт в релиз этого репозитория. Новая версия — запустить её и вписать адрес и checksum.

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
            url: "https://github.com/brobefine/AerialiOS/releases/download/torrserverkit-MatriX.147.1-aerial1/TorrServer-ios-TorrServerKit.xcframework.zip",
            checksum: "dbb8448857c2ee4c71c899142c4dfc26b30bd26f8ab2e48d06de0635cc498a93"
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
