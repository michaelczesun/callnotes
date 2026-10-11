import Foundation

@main
struct RecordingAppsStoreTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let configuration: [String: Any] = [
            "apps": ["custom.call*"], "notesDir": dir.path, "audioDir": dir.path,
            "outDir": dir.path, "summarizer": "off"
        ]
        try JSONSerialization.data(withJSONObject: configuration).write(to: url)
        let store = Store(configPath: url.path, showcase: "settings")
        store.load()
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("FAIL: \(message)") }
            print("PASS: \(message)")
        }
        store.notesDir = "unfinished settings edit"
        store.setRecordingApp(pattern: "custom.call*", enabled: false)
        let disabled = try RecordingAppList.read(from: url)
        check(disabled.enabled.isEmpty && disabled.disabled == ["custom.call*"], "switch saves automatically")
        check(!store.recordingApps.enabled.contains("custom.call*"), "switch reflects saved off state")
        check(try RecordingAppList.readConfiguration(from: url)["notesDir"] as? String == dir.path, "toggle does not save unfinished settings")
        check(store.notesDir == "unfinished settings edit", "unfinished settings stay in the UI")
        store.alwaysRecord(pattern: "custom.call*")
        check(try RecordingAppList.read(from: url).enabled == ["custom.call*"], "Always record re-enables disabled entry")
        check(store.recordingApps.disabled.isEmpty, "Always record updates toggle state")
        try RecordingAppList.writeConfiguration(["apps": ["external.call"], "disabledApps": ["custom.call*"], "notesDir": dir.path], to: url)
        check(store.persist(), "general settings save succeeds")
        check(try RecordingAppList.read(from: url).enabled == ["external.call"], "general settings does not resurrect stale enabled entries")
        check(try RecordingAppList.readConfiguration(from: url)["notesDir"] as? String == "unfinished settings edit", "general settings still saves UI edits")
        let beforeFailure = store.recordingApps
        try Data("broken JSON".utf8).write(to: url)
        store.setRecordingApp(pattern: "external.call", enabled: false)
        check(store.recordingApps == beforeFailure, "failed save restores previous switch state")
        check(!store.status.isEmpty, "failed toggle shows error")
        check(try String(contentsOf: url, encoding: .utf8) == "broken JSON", "failed toggle leaves broken config intact")
        print("All recording-list Store tests passed")
    }
}
