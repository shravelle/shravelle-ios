// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Shravelle",
    platforms: [.iOS(.v13), .macOS(.v11), .tvOS(.v13)],
    products: [.library(name: "Shravelle", targets: ["Shravelle"])],
    targets: [.target(name: "Shravelle")]
)
