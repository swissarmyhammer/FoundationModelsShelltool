// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FoundationModelsShelltool",
    // macOS only: the shell tool spawns child processes via `Subprocess`
    // (posix_spawn) and runs `/bin/sh -c`, neither of which exists on iOS, so
    // there is no iOS platform here.
    platforms: [
        .macOS(.v26),
    ],
    products: [
        // Core library: the shell operations, `ShellContext`, `ShellState`,
        // `ShellRunner`, `OutputBuffer`, `ShellPolicy`, and the output types.
        // Exposed so downstream tools (and the `shell-demo` example) can embed
        // the operations directly, mirroring how the upstream package exposes
        // `Operations`.
        .library(name: "ShellTool", targets: ["ShellTool"]),
    ],
    dependencies: [
        // The `@Operation` macro, schema fusion, `OperationTool` dispatch, and
        // the ArgumentParser CLI driver. Private repo, pinned to `main`.
        .package(
            url: "git@github.com:swissarmyhammer/FoundationModelsOperationTool.git",
            branch: "main"
        ),
        // Structured concurrency child-process API used by `ShellRunner` to
        // spawn commands and stream stdout/stderr line by line. Lives under the
        // `swiftlang` org (the former `apple/swift-subprocess` path 404s).
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            exact: "1.0.0-beta.1"
        ),
        // YAML parsing for the stacked `ShellPolicy` configuration files.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // Core library target: the shell operations and their supporting
        // runtime (spawning, output buffering, policy). Applying `@Operation`
        // pulls in `Operations`; `Subprocess` runs the children; `Yams` reads
        // the policy config.
        .target(
            name: "ShellTool",
            dependencies: [
                .product(name: "Operations", package: "FoundationModelsOperationTool"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),

        // Example: a `shell-demo` executable exercising the shell operations
        // through the CLI driver end to end. Kept as a target of the root
        // package (not a nested package), mirroring the upstream layout where
        // the example tools live under `Examples/`.
        .executableTarget(
            name: "shell-demo",
            dependencies: [
                "ShellTool",
                .product(name: "Operations", package: "FoundationModelsOperationTool"),
                .product(name: "OperationsCLI", package: "FoundationModelsOperationTool"),
            ],
            path: "Examples/ShellDemo/Sources/shell-demo"
        ),

        // Tests for the core library. `@testable` so the tests can reach the
        // package-internal runtime types directly.
        .testTarget(
            name: "ShellToolTests",
            dependencies: ["ShellTool"]
        ),
    ]
)
