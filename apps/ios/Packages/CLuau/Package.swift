// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CLuau",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CLuau", targets: ["CLuau"]),
    ],
    targets: [
        .target(
            name: "CLuau",
            path: "Sources/CLuau",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("luau/Common/include"),
                .headerSearchPath("luau/Ast/include"),
                .headerSearchPath("luau/Bytecode/include"),
                .headerSearchPath("luau/Compiler/include"),
                .headerSearchPath("luau/VM/include"),
                .headerSearchPath("luau/VM/src"),
                .headerSearchPath("luau/Compiler/src"),
                .headerSearchPath("luau/Bytecode/src"),
                .define("LUA_USE_LONGJMP", to: "1"),
                .define("LUAI_MAXCSTACK", to: "1000000"),
                .define("LUA_VECTOR_SIZE", to: "3"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
