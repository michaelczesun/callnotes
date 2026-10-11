import Foundation

@main struct AppTextTests {
    static func main() throws {
        func check(_ value: Bool, _ description: String) {
            guard value else { fatalError("FAIL: \(description)") }
            print("PASS: \(description)")
        }
        let en = AppText(language: "en"), de = AppText(language: "de")
        check(en.phase("Transkription läuft…") == "Transcribing…", "English UI translates legacy German progress")
        check(en.phase("Sprecher-Erkennung…") == "Detecting speakers…", "speaker detection progress is English")
        check(en.phase("KI-Zusammenfassung…") == "AI summary…", "summary progress is English")
        check(en.phase("Archiv & Ablage…") == "Archiving & delivery…", "archive progress is English")
        check(de.phase("Transcribing…") == "Transkription läuft…", "German UI can display English pipeline state")
        check(en.phase("Unbekannter Status") == "Processing…", "unknown backend progress uses localized fallback")
        check(en.speaker("Sprecher 1") == "Speaker 1", "legacy speaker label is displayed in English")
        check(en.speaker("Sprecher 10") == "Speaker 10", "speaker numbering remains intact")
        check(de.speaker("Speaker 10") == "Sprecher 10", "speaker display follows German UI")
        check(en.speaker("Ich") == "You" && en.speaker("Gesprächspartner") == "Caller", "built-in speaker names are English")
        check(en.speaker("Jürgen") == "Jürgen", "real participant names are preserved")
        check(en.failureReason("beide Spuren leer/nicht transkribierbar") == "Both audio tracks are empty or could not be transcribed.", "legacy empty-track error is English")
        check(en.failureReason("Dialog-Merge leer") == "The merged transcript is empty.", "legacy merge error is English")
        check(en.failureReason("Whisper-Modell fehlt (config 'whisperModel'): nicht gesetzt") == "Whisper model missing (whisperModel): not configured", "legacy missing-model default is English")
        check(en.failureReason("Whisper-Modell fehlt (config 'whisperModel'): /tmp/model.bin") == "Whisper model missing (whisperModel): /tmp/model.bin", "failure context path is retained")
        check(en.failureReason("Ein unbekannter Fehler") == "Processing failed. See the processing log for details.", "unknown backend error cannot leak German UI copy")
        check(en.recentCall("2026-10-08-1207-anruf-via-whatsapp.md", appName: "WhatsApp") == "Call via WhatsApp — 2026-10-08 12:07", "German generated filename has an English display title")
        check(de.recentCall("2026-10-08-1207-call-meeting.md", appName: nil) == "Anruf — 2026-10-08 12:07", "generated English filename has a German display title")
        check(en.recentCall("2026-10-08-1207-anruf-meeting-2.md", appName: nil) == "Call — 2026-10-08 12:07", "duplicate-call suffix retains call identity")
        check(en.recentCall("Meine eigene Notiz.md", appName: nil) == "Meine eigene Notiz.md", "user-authored filenames are preserved")
        check(AppLanguage.resolve(configured: "en", override: nil, preferred: ["de-DE"]) == "en", "explicit English beats German system language")
        check(AppLanguage.resolve(configured: "de", override: "en", preferred: ["de"]) == "en", "environment override takes precedence")
        check(AppLanguage.resolve(configured: "en", override: "de-AT", preferred: ["en"]) == "de", "regional environment overrides are recognized")
        check(AppLanguage.resolve(configured: "system", override: nil, preferred: ["de-DE", "en-US"]) == "de", "system German is resolved")
        check(AppLanguage.resolve(configured: "system", override: nil, preferred: ["pt-PT", "de-DE"]) == "en", "unsupported primary UI language defaults to English")
        check(AppLanguage.resolve(configured: nil, override: nil, preferred: []) == "en", "missing language defaults to English")
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [NSLocalizedDescriptionKey: "Zugriff verweigert"])
        check(en.error(error) == "Permission denied.", "German system error descriptions do not leak into English UI")
        let other = NSError(domain: "Test", code: 19, userInfo: [NSLocalizedDescriptionKey: "Fehler"])
        check(en.error(other) == "Operation failed (Test, code 19). See the app log for details.", "unknown error displays localized explanation and code")
        print("All app-text tests passed")
    }
}
