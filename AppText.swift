// App-owned display text. Backend identifiers and user content remain intact.
import Foundation

enum AppLanguage {
    static func resolve(configured: String?, override: String?, preferred: [String]) -> String {
        if let override, !override.isEmpty { return override.lowercased().hasPrefix("de") ? "de" : "en" }
        if configured == "en" || configured == "de" { return configured! }
        return preferred.first?.lowercased().hasPrefix("de") == true ? "de" : "en"
    }
}

struct AppText {
    let language: String
    var isGerman: Bool { language == "de" }
    func text(_ de: String, _ en: String) -> String { isGerman ? de : en }

    func phase(_ raw: String) -> String {
        let pairs = [
            ("Transkription läuft…", "Transcribing…"),
            ("Sprecher-Erkennung…", "Detecting speakers…"),
            ("KI-Zusammenfassung…", "AI summary…"),
            ("Archiv & Ablage…", "Archiving & delivery…")
        ]
        for (de, en) in pairs where raw == de || raw == en { return text(de, en) }
        return text("Verarbeitung…", "Processing…")
    }

    func speaker(_ raw: String) -> String {
        let pattern = #"^(?:Sprecher|Speaker) (\d+)$"#
        if let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let range = Range(match.range(at: 1), in: raw) {
            return text("Sprecher", "Speaker") + " " + raw[range]
        }
        switch raw {
        case "Ich", "Me", "You": return text("Ich", "You")
        case "Gesprächspartner", "Caller": return text("Gesprächspartner", "Caller")
        default: return raw
        }
    }

    func failureReason(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Whisper-Modell fehlt (config 'whisperModel'): ", "Whisper model missing (whisperModel): "] where value.hasPrefix(prefix) {
            var context = String(value.dropFirst(prefix.count))
            if context == "nicht gesetzt" || context == "not configured" { context = text("nicht gesetzt", "not configured") }
            return text("Whisper-Modell fehlt (config 'whisperModel'): ", "Whisper model missing (whisperModel): ") + context
        }
        switch value {
        case "beide Spuren leer/nicht transkribierbar", "Beide Spuren sind leer oder nicht transkribierbar.", "Both audio tracks are empty or could not be transcribed.":
            return text("Beide Spuren sind leer oder nicht transkribierbar.", "Both audio tracks are empty or could not be transcribed.")
        case "Dialog-Merge leer", "Das zusammengeführte Transkript ist leer.", "The merged transcript is empty.":
            return text("Das zusammengeführte Transkript ist leer.", "The merged transcript is empty.")
        default:
            return text("Verarbeitung fehlgeschlagen. Details stehen im Verarbeitungsprotokoll.", "Processing failed. See the processing log for details.")
        }
    }

    func recentCall(_ filename: String, appName: String?) -> String {
        let pattern = #"^(\d{4}-\d{2}-\d{2})-(\d{2})(\d{2})-(?:anruf|call)-.+\.md$"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let date = Range(match.range(at: 1), in: filename),
              let hour = Range(match.range(at: 2), in: filename),
              let minute = Range(match.range(at: 3), in: filename) else { return filename }
        var title = text("Anruf", "Call")
        if let appName, !appName.isEmpty, appName != "unbekannt", appName != "unknown" { title += " via " + appName }
        return "\(title) — \(filename[date]) \(filename[hour]):\(filename[minute])"
    }

    func error(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return text("Zugriff verweigert.", "Permission denied.")
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return text("Die Datei wurde nicht gefunden.", "The file was not found.")
            case NSFileWriteOutOfSpaceError:
                return text("Nicht genügend freier Speicherplatz.", "Not enough free disk space.")
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(EACCES), Int(EPERM): return text("Zugriff verweigert.", "Permission denied.")
            case Int(ENOENT): return text("Die Datei wurde nicht gefunden.", "The file was not found.")
            case Int(ENOSPC): return text("Nicht genügend freier Speicherplatz.", "Not enough free disk space.")
            default: break
            }
        }
        return text("Vorgang fehlgeschlagen (\(ns.domain), Code \(ns.code)). Details stehen im App-Protokoll.",
                    "Operation failed (\(ns.domain), code \(ns.code)). See the app log for details.")
    }
}
