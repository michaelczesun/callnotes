import Foundation

@main
struct RecordingAppsWatchTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("FAIL: \(message)") }
            print("PASS: \(message)")
        }
        try RecordingAppList.writeConfiguration([
            "apps": ["custom.call*", "custom.call*"], "disabledApps": ["com.apple.CoreSpeech*"],
            "minSeconds": 25, "stopGraceSeconds": 8, "tapScope": "app", "outDir": dir.path
        ], to: url)
        let cfg = try WatchConfig.load(url.path)
        check(cfg.apps == ["custom.call*"], "recorder loads normalized enabled list")
        check(cfg.minSeconds == 25 && cfg.stopGraceSeconds == 8 && cfg.outDir == dir.path, "recorder retains other startup settings")
        var runtime = RecordingAppReload(enabled: cfg.apps)
        check(runtime.matches("custom.call.helper"), "enabled app triggers recorder matching")
        check(!runtime.matches("com.apple.CoreSpeech.corespeech"), "disabled CoreSpeech cannot trigger recording")
        _ = try RecordingAppList.setEnabled(false, pattern: "custom.call*", at: url)
        check(try runtime.reload(from: url, isRecording: true) == false, "disabling active app does not interrupt its recording")
        check(runtime.matches("custom.call.helper"), "active recording retains old match")
        _ = try RecordingAppList.setEnabled(true, pattern: "second.call", at: url)
        _ = try RecordingAppList.setEnabled(true, pattern: "latest.call", at: url)
        check(try runtime.reload(from: url, isRecording: false), "helper reloads after recording ends")
        check(!runtime.matches("custom.call.helper") && runtime.matches("latest.call") && runtime.matches("second.call"), "next call uses latest saved list")
        check(cfg.minSeconds == 25 && cfg.stopGraceSeconds == 8, "list reload leaves other recorder settings unchanged")
        print("All recording-list recorder tests passed")
    }
}
