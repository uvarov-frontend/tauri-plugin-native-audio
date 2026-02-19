// swift-tools-version:5.3

import PackageDescription

let package = Package(
  name: "tauri-plugin-native-audio",
  platforms: [
    .iOS(.v13)
  ],
  products: [
    .library(
      name: "tauri-plugin-native-audio",
      type: .static,
      targets: ["tauri-plugin-native-audio"]
    )
  ],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api")
  ],
  targets: [
    .target(
      name: "tauri-plugin-native-audio",
      dependencies: [
        .byName(name: "Tauri")
      ],
      path: "Sources"
    )
  ]
)
