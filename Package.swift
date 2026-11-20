// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ComprehensionLedger",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ComprehensionLedger", targets: ["ComprehensionLedger"])
    ],
    targets: [
        .target(name: "ComprehensionLedger"),
        .testTarget(name: "ComprehensionLedgerTests", dependencies: ["ComprehensionLedger"])
    ]
)
