import Foundation

@main struct AppTextStoreTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("state/pending"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("failed/fixture"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.json")
        try RecordingAppList.writeConfiguration(["uiLanguage": "en", "language": "de", "apps": [],
                                                 "outDir": dir.path, "notesDir": dir.path, "audioDir": dir.path], to: config)
        try RecordingAppList.writeConfiguration(["stamp": "fixture", "phase": "Sprecher-Erkennung…"], to: dir.appendingPathComponent("state/processing.json"))
        try RecordingAppList.writeConfiguration(["stamp": "fixture", "app": "WhatsApp", "note": dir.appendingPathComponent("note.md").path,
                                                 "speakers": [["label": "Sprecher 1", "suggestion": "Alice"], ["label": "Sprecher 10", "suggestion": "Bob"]]],
                                                to: dir.appendingPathComponent("state/pending/fixture.json"))
        try "Dialog-Merge leer".write(to: dir.appendingPathComponent("failed/fixture/fail-reason.txt"), atomically: true, encoding: .utf8)
        let name = "2026-10-08-1207-anruf-via-whatsapp.md"
        try "---\napp: WhatsApp\n---\n# Deutsche Überschrift\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let store = Store(configPath: config.path, showcase: "settings")
        store.load()
        store.poll()
        func check(_ value: Bool, _ description: String) {
            guard value else { fatalError("FAIL: \(description)") }
            print("PASS: \(description)")
        }
        check(store.recentCallTitles[name] == "Call via WhatsApp — 2026-10-08 12:07", "Store shows a localized call title using note metadata")
        check(store.processingPhase == "Detecting speakers…", "Store displays German pipeline state in English")
        check(store.failedReason == "The merged transcript is empty.", "Store displays legacy German failure in English")
        check(store.pendings[0].speakers.map(\.label) == ["Sprecher 1", "Sprecher 10"], "speaker assignment identifiers stay unchanged")
        check(store.key(store.pendings[0], store.pendings[0].speakers[1]).hasSuffix("|Sprecher 10"), "assignment key uses original label")
        check(try RecordingAppList.readConfiguration(from: config)["language"] as? String == "de", "English display does not change transcription settings")
        print("All app-text Store tests passed")
    }
}
