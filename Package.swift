// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sat-facturas-ios",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        // La app iOS en Xcode dependerá de este producto.
        .library(name: "SATKit", targets: ["SATKit"]),
    ],
    targets: [
        // Núcleo: e.firma, sobres SOAP, Descarga Masiva, parser de CFDI. Sin dependencias.
        .target(name: "SATKit", path: "SATKit"),
        // CLI de pruebas en la Mac.
        .executableTarget(name: "satctl", dependencies: ["SATKit"], path: "cli"),
        .testTarget(
            name: "SATKitTests",
            dependencies: ["SATKit"],
            path: "Tests/SATKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
