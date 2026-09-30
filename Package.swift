// swift-tools-version:5.9
import PackageDescription

// The embedded Info.plist carries NSAudioCaptureUsageDescription, which macOS
// wants before it lets a process tap another app's audio.
let infoPlist = Context.packageDirectory + "/Sources/huddle-leveler/Info.plist"

let package = Package(
    name: "HuddleLeveler",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "LevelerDSP", path: "Sources/LevelerDSP"),
        .executableTarget(
            name: "huddle-leveler",
            dependencies: ["LevelerDSP"],
            path: "Sources/huddle-leveler",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
        .testTarget(name: "LevelerDSPTests", dependencies: ["LevelerDSP"], path: "Tests"),
    ]
)
