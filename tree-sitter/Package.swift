// swift-tools-version:5.3

import Foundation
import PackageDescription

var sources = ["src/parser.c"]
if FileManager.default.fileExists(atPath: "src/scanner.c") {
    sources.append("src/scanner.c")
}

let package = Package(
    name: "TreeSitterPostulateParser",
    products: [
        .library(name: "TreeSitterPostulateParser", targets: ["TreeSitterPostulateParser"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "TreeSitterPostulateParser",
            dependencies: [],
            path: ".",
            sources: sources,
            resources: [
                .copy("queries")
            ],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        ),
        .testTarget(
            name: "TreeSitterPostulateParserTests",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                "TreeSitterPostulateParser",
            ],
            path: "bindings/swift/TreeSitterPostulateParserTests"
        )
    ],
    cLanguageStandard: .c11
)
