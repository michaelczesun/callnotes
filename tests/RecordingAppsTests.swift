import Foundation

// These tests catch lost exclusions, stale config overwrites, and mid-call reloads.
@main
struct RecordingAppsTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        func fixture(_ config: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: config).write(to: url)
        }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            print("PASS: \(message)")
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError("FAIL: \(message)") }
            catch { print("PASS: \(message)") }
        }
        try fixture(["apps": ["net.whatsapp.WhatsApp", "custom.call*", "custom.call*"], "notesDir": "original", "unknown": ["keep": true]])
        let original = try RecordingAppList.read(from: url)
        check(original.enabled == ["net.whatsapp.WhatsApp", "custom.call*"], "load deduplicates enabled entries")
        check(original.disabled.isEmpty, "legacy config needs no disabled metadata")
        check(!original.enabled.contains("com.apple.CoreSpeech*"), "catalogue does not enable CoreSpeech")
        check(original.entries.contains { $0.pattern == "com.apple.CoreSpeech*" }, "catalogue includes disabled CoreSpeech")
        check(original.entries.filter { $0.pattern == "custom.call*" }.count == 1, "custom entries appear once")
        let off = try RecordingAppList.setEnabled(false, pattern: "custom.call*", at: url)
        check(off.enabled == ["net.whatsapp.WhatsApp"], "disable removes only selected pattern")
        check(off.disabled == ["custom.call*"], "disabled custom entry is remembered")
        let relaunched = try RecordingAppList.read(from: url)
        check(relaunched.entries.contains { $0.pattern == "custom.call*" } && relaunched.disabled == ["custom.call*"], "disabled entry survives relaunch")
        var disk = try RecordingAppList.readConfiguration(from: url)
        disk["notesDir"] = "external change"
        disk["apps"] = ["net.whatsapp.WhatsApp", "external.call"]
        try fixture(disk)
        let on = try RecordingAppList.setEnabled(true, pattern: "custom.call*", at: url)
        check(on.enabled == ["net.whatsapp.WhatsApp", "external.call", "custom.call*"], "toggle merges latest externally edited enabled list")
        check(on.disabled.isEmpty, "re-enable removes disabled metadata")
        disk = try RecordingAppList.readConfiguration(from: url)
        check(disk["notesDir"] as? String == "external change", "toggle preserves unrelated external settings")
        check((disk["unknown"] as? [String: Bool]) == ["keep": true], "toggle preserves unknown fields")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o600, "config is private after atomic save")
        let merged = try RecordingAppList.saveSettings(["notesDir": "saved edit"], at: url)
        check(merged["apps"] as? [String] == ["net.whatsapp.WhatsApp", "external.call", "custom.call*"], "general settings save preserves latest recording list")
        check(RecordingAppList.matches("custom.call.helper", patterns: on.enabled), "trailing wildcard matches helpers")
        check(!RecordingAppList.matches("custom.other", patterns: on.enabled), "unrelated bundle does not match")
        check(RecordingAppList.matches("any.bundle", patterns: ["*"]), "global wildcard retains existing semantics")
        check(!RecordingAppList.matches("net.whatsapp.WhatsApp.helper", patterns: ["net.whatsapp.WhatsApp"]), "exact entries do not match helpers")
        let broad = RecordingAppList(enabled: ["com.apple.*"], disabled: ["com.apple.CoreSpeech*"])
        check(RecordingAppList.matches("com.apple.CoreSpeech", patterns: broad.enabled), "disabled metadata is not a denylist")
        var runtime = RecordingAppReload(enabled: ["old.call"])
        try fixture(["apps": ["new.call"], "minSeconds": 99])
        check((try? runtime.reload(from: url, isRecording: true)) == false, "reload waits while recording")
        check(runtime.enabled == ["old.call"], "active call keeps original list")
        check((try? runtime.reload(from: url, isRecording: false)) == true, "idle helper applies latest list")
        check(runtime.enabled == ["new.call"], "idle helper sees new list")
        check((try? runtime.reload(from: url, isRecording: false)) == false, "unchanged list is not reapplied")
        try Data("invalid JSON".utf8).write(to: url)
        rejects("invalid config is rejected") { _ = try runtime.reload(from: url, isRecording: false) }
        check(runtime.enabled == ["new.call"], "invalid config retains last working list")
        let damaged = try Data(contentsOf: url)
        rejects("toggle refuses malformed config") { _ = try RecordingAppList.setEnabled(true, pattern: "new.call", at: url) }
        check((try? Data(contentsOf: url)) == damaged, "failed save leaves config unchanged")
        try fixture(["apps": "wrong type"])
        rejects("invalid enabled-list type is rejected") { _ = try RecordingAppList.read(from: url) }
        rejects("missing config is not replaced with partial settings") {
            _ = try RecordingAppList.setEnabled(true, pattern: "new.call", at: dir.appendingPathComponent("missing.json"))
        }
        let blocked = dir.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        rejects("write failure is reported") { try RecordingAppList.writeConfiguration(["apps": []], to: blocked) }
        check(FileManager.default.fileExists(atPath: blocked.path), "write failure preserves existing destination")
        print("All recording-list tests passed")
    }
}
