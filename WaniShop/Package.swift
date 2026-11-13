// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WaniShop",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "WaniShop", targets: ["WaniShop"]),
    ],
    targets: [
        .target(name: "WaniShop"),
    ]
)
