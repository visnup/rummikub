// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "RummikubKit",
  platforms: [.iOS(.v27), .macOS(.v27)],
  products: [
    .library(name: "RummikubKit", targets: ["RummikubKit"])
  ],
  targets: [
    // Recognition's pixel loops take seconds a frame unoptimized, so debug builds optimize too.
    .target(name: "RummikubKit", swiftSettings: [.unsafeFlags(["-O"])]),
    .executableTarget(name: "bench", dependencies: ["RummikubKit"]),
    .executableTarget(name: "scan", dependencies: ["RummikubKit"]),
    .testTarget(name: "RummikubKitTests", dependencies: ["RummikubKit"]),
  ]
)
