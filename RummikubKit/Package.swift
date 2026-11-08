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
    .target(name: "RummikubKit", resources: [.copy("References.bin")], swiftSettings: [.unsafeFlags(["-O"])]),
    .executableTarget(name: "bench", dependencies: ["RummikubKit"]),
    .executableTarget(name: "label", dependencies: ["RummikubKit"]),
    .executableTarget(name: "train", dependencies: ["RummikubKit"]),
    .executableTarget(name: "scan", dependencies: ["RummikubKit"]),
    .executableTarget(name: "score", dependencies: ["RummikubKit"]),
    .executableTarget(name: "words"),
    .testTarget(name: "RummikubKitTests", dependencies: ["RummikubKit"], resources: [.copy("Fixtures")]),
  ]
)
