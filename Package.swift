// swift-tools-version:5.9
import PackageDescription

// The CLI embeds an Info.plist carrying NSAudioCaptureUsageDescription, which
// macOS wants before it lets a process tap another app's audio. The app gets
// the same key from its bundle's Info.plist (scripts/build-app.sh).
let cliInfoPlist = Context.packageDirectory + "/Sources/huddle-leveler/Info.plist"

let package = Package(
    name: "HuddleLeveler",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "huddle-leveler", targets: ["huddle-leveler"]),
        .executable(name: "HuddleLeveler", targets: ["HuddleLeveler"]),
    ],
    targets: [
        .target(name: "LevelerDSP", path: "Sources/LevelerDSP"),
        .target(name: "LevelerCore", dependencies: ["LevelerDSP"], path: "Sources/LevelerCore"),
        .executableTarget(
            name: "huddle-leveler",
            dependencies: ["LevelerCore"],
            path: "Sources/huddle-leveler",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist]),
            ]
        ),
        .executableTarget(
            name: "HuddleLeveler",
            dependencies: ["LevelerCore"],
            path: "Sources/HuddleLevelerApp",
            exclude: ["Info.plist"]
        ),
        .testTarget(name: "LevelerDSPTests", dependencies: ["LevelerDSP"], path: "Tests"),
    ]
)
