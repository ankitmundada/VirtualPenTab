// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SideScreen",
    platforms: [
        // Floor is ScreenCaptureKit basics (12.3) + OSAllocatedUnfairLock /
        // SCStreamConfiguration.capturesAudio (13.0). CGVirtualDisplay is a
        // private API present well before 13 — it does NOT require 14.
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "SideScreen",
            targets: ["SideScreen"])
    ],
    targets: [
        // Pure pen data types + wire codec. Kept as its own library target so
        // it can be unit-tested by a plain executable — XCTest ships only with
        // full Xcode, which a Command Line Tools checkout does not have.
        .target(
            name: "PenCore",
            path: "PenCore"),
        .target(
            name: "DisplayCore",
            path: "DisplayCore"),
        .executableTarget(
            name: "CoreTests",
            dependencies: ["PenCore", "DisplayCore"],
            path: "CoreTests"),
        .executableTarget(
            name: "SideScreen",
            dependencies: ["PenCore", "DisplayCore"],
            path: "Sources",
            cSettings: [
                .unsafeFlags(["-I", "Sources"])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-fmodule-map-file=Sources/module.modulemap"])
            ]),
        .testTarget(
            name: "SideScreenTests",
            dependencies: ["SideScreen"],
            path: "Tests/SideScreenTests",
            cSettings: [
                .unsafeFlags(["-I", "Sources"])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-fmodule-map-file=Sources/module.modulemap"])
            ]
        )
    ]
)
