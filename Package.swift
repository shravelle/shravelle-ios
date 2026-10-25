// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "Shravelle",
    platforms: [.iOS(.v12), .macOS(.v10_15), .tvOS(.v12)],
    products: [.library(name: "Shravelle", targets: ["Shravelle"])],
    targets: [.target(name: "Shravelle")]
)
