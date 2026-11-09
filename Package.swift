// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Sidebar",
  platforms: [.macOS(.v14)],
  targets: [
    // Pure logic: parsing Chrome's files and AppleScript output, window rules, layout.
    .target(name: "SidebarCore"),
    // The menu-bar app. UI code, so main-actor by default.
    .executableTarget(
      name: "Sidebar",
      dependencies: ["SidebarCore"],
      swiftSettings: [.defaultIsolation(MainActor.self)],
      linkerSettings: [.linkedFramework("Carbon")]
    ),
    .testTarget(name: "SidebarCoreTests", dependencies: ["SidebarCore"]),
  ]
)
