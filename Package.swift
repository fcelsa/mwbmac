// swift-tools-version:5.9
import PackageDescription

// Client macOS per Mouse Without Borders (PowerToys). Zero dipendenze esterne.
// Quattro moduli (vedi docs/analisi.md §4) più l'eseguibile da riga di comando.
let package = Package(
    name: "mwbmac",
    platforms: [.macOS(.v13)],
    products: [
    ],
    targets: [
        .target(name: "MWBProtocol"),
        .testTarget(name: "MWBProtocolTests", dependencies: ["MWBProtocol"]),
    ]
)
