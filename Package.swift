// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "vsql-swift",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "VSQL", targets: ["VSQL"])
    ],
    targets: [
        // libvsql, compiled from the vsql amalgamation (see
        // scripts/update-amalgamation.sh). vsql.c includes
        // amalgamation/libvsql.c with the warnings that it causes turned off,
        // since a package that's used as a dependency can't have unsafe flags
        // (such as -w).
        .target(
            name: "CVSQL",
            exclude: ["amalgamation", "ios/README.md"],
            cSettings: [
                // Headers that the iOS SDK doesn't have (see ios/README.md).
                .headerSearchPath("ios", .when(platforms: [.iOS]))
            ],
            linkerSettings: [
                // The libraries that V used to link libvsql (LIBVSQL_FLAGS in
                // the amalgamation's vsql.mk).
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("m", .when(platforms: [.linux])),
                .linkedLibrary("dbghelp", .when(platforms: [.windows])),
                .linkedLibrary("user32", .when(platforms: [.windows])),
                .linkedLibrary("winmm", .when(platforms: [.windows])),
                .linkedLibrary("ws2_32", .when(platforms: [.windows])),
                .linkedLibrary("advapi32", .when(platforms: [.windows])),
                .linkedLibrary("bcrypt", .when(platforms: [.windows])),
                // libvsql declares the printf functions itself, which the
                // Universal CRT defines inline.
                .linkedLibrary("legacy_stdio_definitions", .when(platforms: [.windows])),
            ]
        ),
        .target(name: "VSQL", dependencies: ["CVSQL"]),
        .executableTarget(name: "Example", dependencies: ["VSQL"]),
        .testTarget(name: "VSQLTests", dependencies: ["VSQL"]),
    ],
    cLanguageStandard: .gnu11
)
