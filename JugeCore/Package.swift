// swift-tools-version:5.9
// Cœur du juge de ligne : suivi de la balle, rebonds et verdict. Sans dépendance à iOS,
// il se compile et se teste aussi sur Linux (`swift test`), ce qui permet de le vérifier
// en rejouant les détections des vidéos IMG_1299 et IMG_1323.
import PackageDescription

let package = Package(
    name: "JugeCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "JugeCore", targets: ["JugeCore"])],
    targets: [
        .target(name: "JugeCore"),
        .testTarget(name: "JugeCoreTests", dependencies: ["JugeCore"], resources: [.copy("Fixtures")]),
    ]
)
