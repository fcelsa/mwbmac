// swift-tools-version:5.9
import PackageDescription

// Client macOS per Mouse Without Borders (PowerToys). Zero dipendenze esterne.
// Quattro moduli (vedi docs/analisi.md §4) più l'eseguibile da riga di comando.
let package = Package(
    name: "mwbmac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mwbmac", targets: ["mwbmac"]),
        .executable(name: "MWBMacHost", targets: ["MWBMacHost"]),
    ],
    targets: [
        .target(name: "MWBProtocol"),
        .target(name: "MWBTransport", dependencies: ["MWBProtocol"]),
        .target(name: "MWBInputCapture", dependencies: ["MWBProtocol"]),
        .target(name: "MWBEdgeLogic", dependencies: ["MWBProtocol", "MWBTransport", "MWBInputCapture"]),
        .executableTarget(name: "mwbmac", dependencies: ["MWBProtocol", "MWBTransport", "MWBInputCapture", "MWBEdgeLogic"]),
        // App da barra menu; il bundle .app si costruisce con scripts/build-app.sh.
        .executableTarget(name: "MWBMacHost", dependencies: ["MWBProtocol", "MWBTransport", "MWBInputCapture", "MWBEdgeLogic"]),
        .testTarget(name: "MWBProtocolTests", dependencies: ["MWBProtocol"]),
        .testTarget(name: "MWBTransportTests", dependencies: ["MWBTransport", "MWBProtocol"]),
        .testTarget(name: "MWBInputCaptureTests", dependencies: ["MWBInputCapture"]),
        .testTarget(name: "MWBEdgeLogicTests", dependencies: ["MWBEdgeLogic", "MWBProtocol"]),
    ]
)
