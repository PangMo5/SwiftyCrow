// swift-tools-version: 6.0
// QA-only recorder, native input, and SwiftyCrow scene tools.
import PackageDescription
let package = Package(name: "SwiftyCrowVMQA", platforms: [.macOS(.v14)], products: [
 .executable(name: "DemoRecorder", targets: ["DemoRecorder"]),
 .executable(name: "HostRecorder", targets: ["HostRecorder"]),
 .executable(name: "RecorderRelay", targets: ["RecorderRelay"]),
 .executable(name: "HostMouseRelay", targets: ["HostMouseRelay"]),
 .executable(name: "demokey", targets: ["demokey"]),
 .executable(name: "ui-probe", targets: ["QAControl"]),
 .executable(name: "demoqa", targets: ["DemoQA"])
], targets: [
 .target(name: "DemoRecorderKit"), .target(name: "DemoDriverKit"),
 .executableTarget(name: "DemoRecorder", dependencies: ["DemoRecorderKit"]),
 .executableTarget(name: "HostRecorder", dependencies: ["DemoRecorderKit"]),
 .executableTarget(name: "RecorderRelay", dependencies: ["DemoRecorderKit", "DemoDriverKit"]),
 .executableTarget(name: "HostMouseRelay", dependencies: ["DemoDriverKit"]),
 .executableTarget(name: "demokey", dependencies: ["DemoDriverKit"]),
 .executableTarget(name: "QAControl", dependencies: ["DemoDriverKit"]),
 .executableTarget(name: "DemoQA", dependencies: ["DemoDriverKit"]),
 .testTarget(name: "RecorderTests", dependencies: ["DemoRecorderKit"])
])
