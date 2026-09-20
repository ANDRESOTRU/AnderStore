// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnderLogic",
    platforms: [.macOS(.v13)],
    products: [.library(name: "AnderLogic", targets: ["AnderLogic"])],
    targets: [
        .target(
            name: "AnderLogic",
            path: "LiveContainerSwiftUI/Ander",
            sources: ["AnderLogic.swift"]
        ),
        .testTarget(
            name: "AnderLogicTests",
            dependencies: ["AnderLogic"],
            path: "Tests/AnderLogicTests"
        ),
    ]
)
