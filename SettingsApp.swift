// CallNotes.app v2.4.1 — Menueleisten-App fuer den Anruf-Autopiloten (calltap)
// - Live-Pegel beider Spuren waehrend des Anrufs (du + Gegenseite)
// - Popup bei Anruf-Erkennung: Teilnehmer-Namen (mehrere)
// - Verarbeitungs-Status (Transkription/Diarisierung/KI) nach dem Auflegen
// - Sprecher-Zuordnung mit Hoer-Schnipseln + Dropdown
// - Einstellungen: Speicherorte, Transkription (lokal/Groq), Notiz-Inhalte,
//   Ablage-Ziele (Apple Notes, Nextcloud, Notion), ntfy
import SwiftUI
import AppKit
import AVFoundation

let kConfigPath = NSString(string: "~/.config/callnotes/config.json").expandingTildeInPath
let kAppVersion = "1.2.4"
let kRepoURL = "https://github.com/michaelczesun/callnotes"

let isGerman: Bool = {
    if let o = ProcessInfo.processInfo.environment["CALLNOTES_LANG"] { return o.hasPrefix("de") }
    // In-App-Wahl aus der Config ("uiLanguage": "de" | "en" | "system")
    if let data = try? Data(contentsOf: URL(fileURLWithPath: kConfigPath)),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let lang = obj["uiLanguage"] as? String, lang == "de" || lang == "en" {
        return lang == "de"
    }
    return Locale.preferredLanguages.first?.hasPrefix("de") ?? false
}()
func L(_ de: String, _ en: String) -> String { isGerman ? de : en }

func tilde(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

func untilde(_ p: String) -> String { NSString(string: p).expandingTildeInPath }

func safeSymbol(_ candidates: [String]) -> String {
    for n in candidates where NSImage(systemSymbolName: n, accessibilityDescription: nil) != nil { return n }
    return "phone.fill"
}

let kKeep = L("— Label behalten —", "— keep label —")
let kCustom = L("Eigener Name…", "Custom name…")
let accent = LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 1.0), Color(red: 0.75, green: 0.35, blue: 0.95)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)

// MARK: - Datenmodelle

struct CurrentCall: Equatable {
    let dir: String
    let appName: String
    let start: Date
}

struct PendingSpeaker: Identifiable {
    var id: String { label }
    let label: String
    let clip: String
    let suggestion: String
    let totalSec: Double
}

struct PendingCall: Identifiable {
    var id: String { path }
    let path: String
    let stamp: String
    let app: String
    let note: String
    let speakers: [PendingSpeaker]
    let participants: [String]
}

// MARK: - Store

final class Store: ObservableObject {
    // Speicherorte
    @Published var notesDir = "~/CallNotes/notes"
    @Published var audioDir = "~/CallNotes/audio"
    @Published var mirrorDir = ""
    // Transkription + Integrationen
    @Published var transcriber = "local"
    @Published var groqApiKey = ""
    @Published var summarizer = "claude"
    @Published var sumUrl = ""
    @Published var sumModel = ""
    @Published var sumKey = ""
    @Published var sections: Set<String> = ["kurzfassung", "besprochen", "todos"]
    @Published var destNotes = false
    @Published var destNextcloud = false
    @Published var destNotion = false
    @Published var ncUrl = ""
    @Published var ncUser = ""
    @Published var ncPass = ""
    @Published var notionToken = ""
    @Published var notionParent = ""
    @Published var ntfyUrl = ""
    @Published var uiLanguage = "system"
    // Laufzeit
    @Published var status = ""
    @Published var daemonRunning = false
    @Published var lastNotes: [String] = []
    @Published var failedCount = 0
    @Published var updateAvailable: String? = nil
    @Published var currentCall: CurrentCall? = nil
    @Published var callElapsed = ""
    @Published var micLevels: [Double] = []
    @Published var sysLevels: [Double] = []
    @Published var processingPhase: String? = nil
    @Published var participantFields: [String] = [""]
    @Published var participantsSaved = false
    @Published var pendings: [PendingCall] = []
    @Published var picks: [String: String] = [:]
    @Published var customNames: [String: String] = [:]
    static weak var shared: Store?
    var setupDone = true

    private var raw: [String: Any] = [:]
    private var baseDir = untilde("~/CallNotes")
    private var scriptDir = ""
    private var timer: Timer?
    private var levelTimer: Timer?
    private var player: AVAudioPlayer?
    private var poppedFor = ""
    private var tick = 0

    init(showcase: String? = nil) {
        load()
        if let mode = showcase {
            setupDemo(mode)
            return // Schaufenster: keine Timer, kein Wizard, kein Update-Check
        }
        poll()
        // .common-Mode: weiterlaufen, auch wenn ein Menue/Drag die RunLoop im Tracking haelt
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        checkForUpdate()
        let u = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdate() }
        RunLoop.main.add(u, forMode: .common)
        Store.shared = self
        if !setupDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.setupDone else { return }
                SetupWizard.shared.show(store: self)
            }
        }
    }

    // Demo-Zustand fuer README-Screenshots (CALLNOTES_SHOWCASE=call|pending|settings)
    private func setupDemo(_ mode: String) {
        daemonRunning = true
        status = ""
        failedCount = 0
        updateAvailable = nil
        // ALLE Werte neutral ueberschreiben — Screenshots landen im public Repo,
        // hier darf nichts aus der echten Config durchsickern (ntfy-Topic, Keys!)
        notesDir = "~/CallNotes/notes"
        audioDir = "~/CallNotes/audio"
        mirrorDir = "/Volumes/Backup/CallNotes"
        transcriber = "local"
        groqApiKey = ""
        summarizer = "claude"
        sumUrl = ""; sumModel = ""; sumKey = ""
        sections = ["kurzfassung", "besprochen", "todos"]
        destNotes = true
        destNextcloud = false
        destNotion = false
        ncUrl = ""; ncUser = ""; ncPass = ""
        notionToken = ""; notionParent = ""
        ntfyUrl = ""
        lastNotes = [L("2026-07-03-1042-anruf-anna-website-relaunch.md", "2026-07-03-1042-call-anna-website-relaunch.md"),
                     L("2026-07-02-1731-anruf-stefan-catering-angebot.md", "2026-07-02-1731-call-stefan-catering-offer.md")]
        if mode == "call" {
            currentCall = CurrentCall(dir: "/tmp/callnotes-demo", appName: "WhatsApp",
                                      start: Date().addingTimeInterval(-222))
            callElapsed = "3:42"
            micLevels = (0..<42).map { 0.08 + 0.85 * abs(sin(Double($0) * 0.52)) }
            sysLevels = (0..<42).map { 0.08 + 0.80 * abs(sin(Double($0) * 0.37 + 1.4)) }
            participantFields = ["Anna", ""]
        }
        if mode == "pending" {
            let sp = [PendingSpeaker(label: L("Sprecher 1", "Speaker 1"), clip: "", suggestion: "Anna", totalSec: 34),
                      PendingSpeaker(label: L("Sprecher 2", "Speaker 2"), clip: "", suggestion: "Stefan", totalSec: 21)]
            let p = PendingCall(path: "/tmp/callnotes-demo.json", stamp: "2026-07-03_104233", app: "zoom",
                                note: "/tmp/demo.md", speakers: sp, participants: ["Anna", "Stefan"])
            pendings = [p]
            for s in sp { picks[key(p, s)] = s.suggestion }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            ShowcaseWindow.show(store: self, mode: mode)
        }
    }

    func load() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: kConfigPath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = obj
            notesDir = obj["notesDir"] as? String ?? notesDir
            audioDir = obj["audioDir"] as? String ?? audioDir
            mirrorDir = obj["mirrorDir"] as? String ?? ""
            transcriber = obj["transcriber"] as? String ?? "local"
            groqApiKey = obj["groqApiKey"] as? String ?? ""
            summarizer = obj["summarizer"] as? String ?? "claude"
            sumUrl = obj["summarizerUrl"] as? String ?? ""
            sumModel = obj["summarizerModel"] as? String ?? ""
            sumKey = obj["summarizerApiKey"] as? String ?? ""
            if let s = obj["noteSections"] as? [String] { sections = Set(s) }
            let dest = obj["destinations"] as? [String: Any] ?? [:]
            destNotes = dest["appleNotes"] as? Bool ?? false
            destNextcloud = dest["nextcloud"] as? Bool ?? false
            destNotion = dest["notion"] as? Bool ?? false
            ncUrl = obj["nextcloudUrl"] as? String ?? ""
            ncUser = obj["nextcloudUser"] as? String ?? ""
            ncPass = obj["nextcloudAppPass"] as? String ?? ""
            notionToken = obj["notionToken"] as? String ?? ""
            notionParent = obj["notionParent"] as? String ?? ""
            ntfyUrl = obj["ntfyUrl"] as? String ?? ""
            uiLanguage = obj["uiLanguage"] as? String ?? "system"
            setupDone = obj["setupDone"] as? Bool ?? false
            baseDir = untilde(obj["outDir"] as? String ?? "~/CallNotes")
            if let post = obj["postScript"] as? String {
                scriptDir = (untilde(post) as NSString).deletingLastPathComponent
            }
        } else {
            status = L("Keine Config — install.sh ausführen.", "No config — run install.sh.")
        }
        refreshDaemon()
        refreshNotes()
    }

    func persist() -> Bool {
        raw["notesDir"] = notesDir
        raw["audioDir"] = audioDir
        raw["mirrorDir"] = mirrorDir
        raw["transcriber"] = transcriber
        raw["groqApiKey"] = groqApiKey
        raw["summarizer"] = summarizer
        raw["summarizerUrl"] = sumUrl
        raw["summarizerModel"] = sumModel
        raw["summarizerApiKey"] = sumKey
        raw["noteSections"] = Array(sections).sorted()
        raw["destinations"] = ["appleNotes": destNotes, "nextcloud": destNextcloud, "notion": destNotion]
        raw["nextcloudUrl"] = ncUrl
        raw["nextcloudUser"] = ncUser
        raw["nextcloudAppPass"] = ncPass
        raw["notionToken"] = notionToken
        raw["notionParent"] = notionParent
        raw["ntfyUrl"] = ntfyUrl
        raw["uiLanguage"] = uiLanguage
        raw["setupDone"] = setupDone
        guard let d = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let dir = (kConfigPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            // atomar schreiben — der Daemon/die Pipeline darf nie eine halbe JSON sehen
            let tmp = URL(fileURLWithPath: kConfigPath + ".tmp")
            try d.write(to: tmp)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: kConfigPath), withItemAt: tmp)
            return true
        } catch { return false }
    }

    @discardableResult
    private func run(_ argv: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    // MARK: Polling

    func poll() {
        pollCurrentCall()
        pollPendings()
        pollProcessing()
        tick += 1
        if tick % 5 == 0 { refreshDaemon(); refreshNotes() }
    }

    private func pollCurrentCall() {
        let f = baseDir + "/state/current-call.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: f)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dir = obj["dir"] as? String else {
            if currentCall != nil {
                currentCall = nil
                callElapsed = ""
                micLevels = []; sysLevels = []
                participantFields = [""]
                participantsSaved = false
                stopLevelTimer()
                CallPopupPanel.shared.hide()
            }
            return
        }
        // Daemon tot/haengend? levels.json wird sonst alle 0,35s erneuert — bleibt sie
        // laenger stehen, ist die "laufende Aufnahme" eine Leiche und wird ignoriert.
        let levelsPath = dir + "/levels.json"
        if let lAttrs = try? FileManager.default.attributesOfItem(atPath: levelsPath),
           let lMod = lAttrs[.modificationDate] as? Date,
           Date().timeIntervalSince(lMod) > 20 {
            if currentCall != nil {
                currentCall = nil
                callElapsed = ""
                stopLevelTimer()
                CallPopupPanel.shared.hide()
            }
            return
        }
        let start = ISO8601DateFormatter().date(from: obj["start"] as? String ?? "") ?? Date()
        let call = CurrentCall(dir: dir, appName: obj["appName"] as? String ?? "?", start: start)
        if currentCall != call {
            currentCall = call
            participantsSaved = false
            startLevelTimer()
            if poppedFor != dir {
                poppedFor = dir
                participantFields = [""]
                CallPopupPanel.shared.show(store: self)
            }
        }
        let el = Int(Date().timeIntervalSince(start))
        callElapsed = String(format: "%d:%02d", el / 60, el % 60)
    }

    private func startLevelTimer() {
        guard levelTimer == nil else { return }
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self, let call = self.currentCall else { return }
            let f = call.dir + "/levels.json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: f)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.micLevels.append(max(obj["mic"] as? Double ?? 0, 0.04))
            self.sysLevels.append(max(obj["sys"] as? Double ?? 0, 0.04))
            if self.micLevels.count > 42 { self.micLevels.removeFirst(self.micLevels.count - 42) }
            if self.sysLevels.count > 42 { self.sysLevels.removeFirst(self.sysLevels.count - 42) }
        }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func pollProcessing() {
        let f = baseDir + "/state/processing.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: f) else {
            processingPhase = nil
            return
        }
        // Leiche nach Absturz/Kill: jede echte Phase erneuert die Datei deutlich schneller
        if let mod = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mod) > 3600 {
            try? FileManager.default.removeItem(atPath: f)
            processingPhase = nil
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: f)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            processingPhase = nil
            return
        }
        processingPhase = obj["phase"] as? String
    }

    private func pollPendings() {
        let dir = baseDir + "/state/pending"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        var result: [PendingCall] = []
        for f in files {
            let path = dir + "/" + f
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let speakers = (obj["speakers"] as? [[String: Any]] ?? []).map {
                PendingSpeaker(label: $0["label"] as? String ?? "?",
                               clip: $0["clip"] as? String ?? "",
                               suggestion: $0["suggestion"] as? String ?? "",
                               totalSec: $0["totalSec"] as? Double ?? 0)
            }
            result.append(PendingCall(path: path,
                                      stamp: obj["stamp"] as? String ?? f,
                                      app: obj["app"] as? String ?? "?",
                                      note: obj["note"] as? String ?? "",
                                      speakers: speakers,
                                      participants: obj["participants"] as? [String] ?? []))
        }
        if result.map(\.id) != pendings.map(\.id) {
            pendings = result
            for p in result {
                for s in p.speakers where picks[key(p, s)] == nil {
                    picks[key(p, s)] = s.suggestion.isEmpty ? kKeep : s.suggestion
                }
            }
        }
    }

    func key(_ p: PendingCall, _ s: PendingSpeaker) -> String { p.path + "|" + s.label }

    // MARK: Aktionen

    // "Nicht aufnehmen": Marker-Datei setzen — der Daemon stoppt, loescht alles
    // und laesst diesen Anruf in Ruhe.
    func abortRecording() {
        guard let call = currentCall else { return }
        FileManager.default.createFile(atPath: call.dir + "/abort", contents: nil)
        status = L("Aufnahme wird verworfen — dieser Anruf bleibt privat.", "Discarding recording — this call stays private.")
        CallPopupPanel.shared.hide()
    }

    func saveParticipants() {
        guard let call = currentCall else { return }
        let names = participantFields.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let d = try? JSONSerialization.data(withJSONObject: ["names": names], options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: call.dir + "/participants.json"))
            participantsSaved = true
            status = names.isEmpty ? L("Teilnehmer geleert", "Participants cleared") : L("Teilnehmer: \(names.joined(separator: ", "))", "Participants: \(names.joined(separator: ", "))")
        }
        CallPopupPanel.shared.hide()
    }

    func playClip(_ path: String) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        if player == nil { status = L("Hörprobe nicht mehr verfügbar.", "Voice sample no longer available.") }
        player?.play()
    }

    func options(for p: PendingCall, _ s: PendingSpeaker) -> [String] {
        var opts = [kKeep]
        if !s.suggestion.isEmpty { opts.append(s.suggestion) }
        for n in p.participants where !opts.contains(n) { opts.append(n) }
        opts.append(kCustom)
        return opts
    }

    func apply(_ p: PendingCall) {
        var parts: [String] = []
        for s in p.speakers {
            let k = key(p, s)
            var name = picks[k] ?? kKeep
            if name == kCustom { name = (customNames[k] ?? "").trimmingCharacters(in: .whitespaces) }
            if name.isEmpty || name == kKeep { continue }
            name = name.replacingOccurrences(of: ";", with: ",") // Trennzeichen des Mappings
            parts.append("\(s.label)=\(name)")
        }
        let script = scriptDir + "/apply-speakers.sh"
        guard FileManager.default.fileExists(atPath: script) else { status = L("apply-speakers.sh fehlt", "apply-speakers.sh missing"); return }
        status = L("Übernehme Zuordnung …", "Applying names …")
        let mapping = parts.joined(separator: ";")
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let (code, out) = self.run(["/bin/bash", script, p.path, mapping])
            DispatchQueue.main.async {
                self.status = code == 0 ? L("✅ Zuordnung übernommen", "✅ Names applied") : L("❌ Zuordnung fehlgeschlagen: \(out.suffix(140))", "❌ Applying names failed: \(out.suffix(140))")
                self.poll()
            }
        }
    }

    func refreshDaemon() {
        let (code, _) = run(["/bin/launchctl", "print", "gui/\(getuid())/at.dasgeht.callwatch"])
        daemonRunning = code == 0
    }

    func refreshNotes() {
        let dir = untilde(notesDir)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".md") && $0 != "anrufe-moc.md" }.sorted().suffix(4)
        lastNotes = Array(files.reversed())
        failedCount = ((try? FileManager.default.contentsOfDirectory(atPath: baseDir + "/failed")) ?? [])
            .filter { !$0.hasPrefix(".") }.count
    }

    // Sanfter Update-Hinweis (kein Auto-Updater): neuestes GitHub-Release vergleichen
    func checkForUpdate() {
        guard let url = URL(string: "https://api.github.com/repos/michaelczesun/callnotes/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("CallNotes/\(kAppVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let d = data,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async {
                self?.updateAvailable = latest.compare(kAppVersion, options: .numeric) == .orderedDescending ? latest : nil
            }
        }.resume()
    }

    // Fehlgeschlagene Verarbeitungen (Roh-Audio liegt in failed/) erneut anstossen
    func retryFailed() {
        let dir = baseDir + "/failed"
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { !$0.hasPrefix(".") }
        guard !items.isEmpty else { return }
        let script = scriptDir + "/process-call.sh"
        guard FileManager.default.fileExists(atPath: script) else { status = L("process-call.sh fehlt", "process-call.sh missing"); return }
        status = L("Nachverarbeitung von \(items.count) Aufnahme(n) gestartet …", "Reprocessing \(items.count) recording(s) …")
        let logFile = baseDir + "/log/process.log"
        for it in items {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "nohup /bin/bash '\(script)' '\(dir)/\(it)' >> '\(logFile)' 2>&1 &"]
            try? p.run()
        }
    }

    // Kaputte Aufnahmen endgueltig loeschen (z.B. leere Spuren — Retry bringt nichts)
    func discardFailed() {
        let dir = baseDir + "/failed"
        for it in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []) where !it.hasPrefix(".") {
            try? FileManager.default.removeItem(atPath: dir + "/" + it)
        }
        status = L("Fehlgeschlagene Aufnahmen verworfen.", "Failed recordings discarded.")
        refreshNotes()
    }

    // Sprachwechsel: speichern und — falls sich die effektive Sprache aendert —
    // die App blitzschnell selbst neu starten (die Texte werden beim Start aufgeloest).
    func applyLanguageChange() {
        _ = persist()
        let newIsGerman: Bool
        switch uiLanguage {
        case "de": newIsGerman = true
        case "en": newIsGerman = false
        default: newIsGerman = Locale.preferredLanguages.first?.hasPrefix("de") ?? false
        }
        guard newIsGerman != isGerman else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-n", Bundle.main.bundlePath]
        try? proc.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSApp.terminate(nil) }
    }

    func openNote(_ name: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: untilde(notesDir) + "/" + name))
    }

    func saveAndRestart() {
        guard persist() else { status = L("❌ Config nicht schreibbar", "❌ Config not writable"); return }
        let (code, out) = run(["/bin/launchctl", "kickstart", "-k", "gui/\(getuid())/at.dasgeht.callwatch"])
        refreshDaemon()
        status = code == 0 ? L("✅ Gespeichert & Daemon neu gestartet", "✅ Saved & daemon restarted") : "⚠️ \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func syncNow() {
        guard persist() else { status = L("❌ Config nicht schreibbar", "❌ Config not writable"); return }
        guard !mirrorDir.isEmpty else { status = L("Kein Kopie-Ordner gewählt.", "No mirror folder selected."); return }
        let script = scriptDir + "/callnotes-sync.sh"
        guard FileManager.default.fileExists(atPath: script) else { status = L("❌ Sync-Skript fehlt", "❌ Sync script missing"); return }
        status = L("Kopiere …", "Copying …")
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let (code, out) = self.run(["/bin/bash", script])
            DispatchQueue.main.async {
                self.status = code == 0 ? L("✅ Kopiert nach \(tilde(self.mirrorDir))", "✅ Copied to \(tilde(self.mirrorDir))") : L("❌ Kopieren fehlgeschlagen: \(out.suffix(140))", "❌ Copy failed: \(out.suffix(140))")
            }
        }
    }
}

// MARK: - Popup bei Anruf-Erkennung

final class CallPopupPanel {
    static let shared = CallPopupPanel()
    private var panel: NSPanel?

    func show(store: Store) {
        hide()
        let view = NSHostingView(rootView: CallPopupView().environmentObject(store))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 10),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "CallNotes"
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.contentView = view
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.maxX - 360, y: f.maxY - 8))
        }
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Info-Tips (das kleine i neben jedem Feld)

struct InfoTip: View {
    let title: String
    let text: String
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(L("Erklärung: \(title)", "Explanation: \(title)"))
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 270)
        }
    }
}

// MARK: - Hilfe-Fenster

final class HelpWindow {
    static let shared = HelpWindow()
    private var window: NSWindow?

    func show(store: Store) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = NSHostingView(rootView: HelpView().environmentObject(store))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L("CallNotes — Hilfe", "CallNotes — Help")
        w.contentView = view
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

struct HelpTopic: View {
    let icon: String
    let title: String
    let body_: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundColor(.primary)
            Text(.init(body_))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
        }
    }
}

struct HelpView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(accent).frame(width: 40, height: 40)
                        Image(systemName: safeSymbol(["phone.and.waveform.fill", "phone.fill"]))
                            .font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("CallNotes Hilfe", "CallNotes help")).font(.title3.weight(.bold))
                        Text(L("Alles Wichtige zum Einstellen und Nutzen", "Everything you need for setup and use")).font(.caption).foregroundColor(.secondary)
                    }
                }

                Group {
                    Text(L("SO FUNKTIONIERT ES", "HOW IT WORKS")).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                    HelpTopic(icon: "waveform.badge.mic", title: L("Automatische Aufnahme", "Automatic recording"),
                              body_: L("Sobald eine Telefonie-App (FaceTime, iPhone-Anruf, WhatsApp, Zoom, Teams, Signal, Telegram, Discord) dein Mikrofon nutzt, startet die Aufnahme — zwei getrennte Spuren: dein Mikro und der Ton der Gegenseite. Nach dem Auflegen stoppt sie von selbst; Anrufe unter 20 Sekunden werden verworfen.", "As soon as a calling app (FaceTime, iPhone calls, WhatsApp, Zoom, Teams, Signal, Telegram, Discord) uses your microphone, recording starts — two separate tracks: your mic and the caller's audio. It stops automatically when you hang up; calls under 20 seconds are discarded."))
                    HelpTopic(icon: "doc.text", title: L("Die fertige Notiz", "The finished note"),
                              body_: L("Etwa eine Minute nach dem Auflegen liegt die Notiz im Notizen-Ordner: KI-Kurzfassung, besprochene Punkte, Zusagen & To-dos und das komplette Dialog-Transkript mit Sprechern. Dazu ein Audio-Archiv als m4a (links du, rechts Gegenseite).", "About a minute after hanging up, the note appears in your notes folder: an AI summary, discussion points, commitments & to-dos, and the full dialogue transcript with speakers. Plus an m4a audio archive (you on the left, caller on the right)."))
                    HelpTopic(icon: "person.2.wave.2", title: L("Konferenzen & Sprecher-Zuordnung", "Conference calls & speaker assignment"),
                              body_: L("Bei mehreren Stimmen auf der Gegenseite trennt die lokale Sprecher-Erkennung sie in „Sprecher 1..N\u{201C}. Im Menüleisten-Panel erscheint dann „Stimmen erkannt\u{201C}: Hörprobe abspielen ▶︎, Namen im Dropdown wählen (die KI schlägt Namen vor, die im Gespräch fielen), „Zuordnung übernehmen\u{201C} — fertig. Tipp: Trage die Teilnehmer schon während des Anrufs im Popup ein, dann stehen die Namen im Dropdown bereit.", "When there are multiple voices on the other end, local speaker recognition separates them into \u{201C}Speaker 1..N\u{201D}. The menu bar panel then shows \u{201C}Voices detected\u{201D}: play a voice sample ▶︎, pick a name from the dropdown (the AI suggests names mentioned during the call), \u{201C}Apply names\u{201D} — done. Tip: enter participants in the popup during the call so the names are ready in the dropdown."))
                }

                Group {
                    Text(L("FREIGABEN (EINMALIG)", "PERMISSIONS (ONE-TIME)")).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                    HelpTopic(icon: "lock.shield", title: L("Mikrofon + Systemaudio", "Microphone + system audio"),
                              body_: L("Beide Freigaben hängen an „calltap\u{201C} (dem Aufnahme-Helfer). macOS fragt beim ersten Start automatisch. Falls die Gegenseite in Aufnahmen stumm ist: Systemeinstellungen → Datenschutz & Sicherheit → **Bildschirm- & Systemaudioaufnahme** → calltap aktivieren. Fürs Mikrofon: gleicher Ort → **Mikrofon**.", "Both permissions belong to \u{201C}calltap\u{201D} (the recording helper). macOS asks automatically on first launch. If the caller is silent in recordings: System Settings → Privacy & Security → **Screen & System Audio Recording** → enable calltap. For the microphone: same place → **Microphone**."))
                    HelpTopic(icon: "externaldrive", title: L("Externe Festplatte", "External drive"),
                              body_: L("Beim ersten Kopieren auf eine externe Platte fragt macOS nach der Freigabe für „Dateien auf Wechseldatenträgern\u{201C} — einmal erlauben, fertig.", "The first time it copies to an external drive, macOS asks for \u{201C}Removable Volumes\u{201D} access — allow it once, done."))
                    HelpTopic(icon: "note.text", title: L("Apple Notes / Automation", "Apple Notes / Automation"),
                              body_: L("Wenn die Ablage in Apple Notes aktiv ist, fragt macOS beim ersten Anruf nach einer Automation-Freigabe (calltap → Notes) — erlauben.", "If saving to Apple Notes is enabled, macOS asks for an Automation permission on the first call (calltap → Notes) — allow it."))
                }

                Group {
                    Text(L("EINSTELLUNGEN ERKLÄRT", "SETTINGS EXPLAINED")).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                    HelpTopic(icon: "folder", title: L("Speicherorte", "Storage locations"),
                              body_: L("**Notizen**: Zielordner der fertigen .md-Notizen — ideal ist dein Obsidian-Vault. **Audio-Archiv**: die m4a-Dateien. **Kopie (extern)**: optionaler Spiegel z. B. auf der externen Platte; wird nach jedem Anruf synchronisiert, verpasste Syncs werden automatisch nachgeholt.", "**Notes**: destination folder for the finished .md notes — your Obsidian vault is ideal. **Audio archive**: the m4a files. **Mirror (external)**: an optional copy, e.g. on an external drive; synced after every call, and missed syncs are caught up automatically."))
                    HelpTopic(icon: "phone.arrow.down.left", title: L("Warum kommt kein Popup?", "Why is there no popup?"),
                              body_: L("Das Popup erscheint erst, wenn ein Anruf WIRKLICH läuft — die Call-App also dein Mikrofon nutzt. Teams/WhatsApp nur zu öffnen genügt nicht. Test: Ruf jemanden an — das Menüleisten-Symbol wird aktiv und das Popup öffnet sich. Kommt es trotzdem nicht: Der Punkt oben rechts im Panel muss GRÜN sein (sonst ./install.sh erneut ausführen), und die App muss in den Einstellungen unter Apps stehen.",
                                        "The popup only appears once a call is REALLY running — i.e. the call app is using your microphone. Just opening Teams/WhatsApp is not enough. Test: call someone — the menu bar icon becomes active and the popup opens. If it still doesn't: the dot in the panel's top right must be GREEN (otherwise re-run ./install.sh), and the app must be listed under Apps in settings."))
                    HelpTopic(icon: "cpu", title: L("Transkription: Whisper, Parakeet oder Groq", "Transcription: Whisper, Parakeet or Groq"),
                              body_: L("**Whisper** läuft komplett offline auf deinem Mac (privat, bewährt). **Parakeet** (NVIDIA TDT v3) läuft ebenfalls lokal, ist die schnellste Option und kennt keine Whisper-Wiederholungsschleifen — 25 europäische Sprachen; einmalig ~700 MB laden: `./install.sh --with-parakeet`. **Groq** ist eine Cloud-API und bei langen Gesprächen sehr schnell — dafür verlässt das Audio deinen Mac (Key gratis auf console.groq.com).", "**Whisper** runs entirely offline on your Mac (private, proven). **Parakeet** (NVIDIA TDT v3) also runs locally, is the fastest option and has no Whisper-style repetition loops — 25 European languages; one-time ~700 MB download: `./install.sh --with-parakeet`. **Groq** is a cloud API, very fast for long calls — but the audio leaves your Mac (free key at console.groq.com)."))
                    HelpTopic(icon: "brain", title: L("KI-Zusammenfassung: deine Wahl", "AI summary: your choice"),
                              body_: L("**Claude Code** (Standard) nutzt dein bestehendes Claude-Abo auf dem Mac. **Eigene KI** spricht jede OpenAI-kompatible API — OpenAI, Groq, OpenRouter oder komplett lokal & kostenlos via Ollama (dann bleibt wirklich alles auf deinem Mac). **Aus** liefert die Notiz nur mit Transkript. Ohne funktionierende KI bricht nichts: Die Notiz kommt trotzdem.", "**Claude Code** (default) uses your existing Claude subscription on the Mac. **Custom AI** talks to any OpenAI-compatible API — OpenAI, Groq, OpenRouter, or fully local & free via Ollama (then everything really does stay on your Mac). **Off** delivers the note with just the transcript. Nothing breaks without a working AI: the note still arrives."))
                    HelpTopic(icon: "list.bullet.rectangle", title: L("Notiz-Inhalte", "Note contents"),
                              body_: L("Wähle, welche Abschnitte die KI schreibt: Kurzfassung, besprochene Punkte, Zusagen & To-dos, und auf Wunsch einen fertigen **Follow-up-Mail-Entwurf** an die Gegenseite.", "Choose which sections the AI writes: summary, discussion points, commitments & to-dos, and optionally a ready-to-send **follow-up email draft** to the caller."))
                    HelpTopic(icon: "square.and.arrow.up", title: L("Ablage-Ziele", "Save destinations"),
                              body_: L("Zusätzlich zur Notiz im Ordner: **Apple Notes** (Ordner „CallNotes\u{201C}), **Nextcloud** (WebDAV; App-Passwort in Nextcloud unter Einstellungen → Sicherheit erzeugen) und **Notion** (Integration auf notion.so/my-integrations anlegen, Token eintragen, Ziel-Seite über ••• → Verbindungen freigeben; Seiten-ID = die 32 Zeichen aus der Seiten-URL).", "In addition to the note in the folder: **Apple Notes** (\u{201C}CallNotes\u{201D} folder), **Nextcloud** (WebDAV; create an app password in Nextcloud under Settings → Security) and **Notion** (create an integration at notion.so/my-integrations, paste the token, share the target page via ••• → Connections; page ID = the 32 characters from the page URL)."))
                    HelpTopic(icon: "bell.badge", title: L("Push (ntfy)", "Push (ntfy)"),
                              body_: L("Kostenlose Push-Nachricht aufs Handy nach jeder Notiz: ntfy.sh-App installieren, ein Thema abonnieren und die URL (https://ntfy.sh/dein-thema) eintragen.", "Free push notification to your phone after every note: install the ntfy.sh app, subscribe to a topic, and enter the URL (https://ntfy.sh/your-topic)."))
                }

                Group {
                    Text(L("WENN ETWAS HAKT", "TROUBLESHOOTING")).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                    HelpTopic(icon: "questionmark.circle", title: L("Aufnahme startet nicht", "Recording doesn't start"),
                              body_: L("Öffne das Protokoll unter `~/CallNotes/log/callwatch.log`. Steht dort ein Hinweis auf eine „nicht gelistete App\u{201C}, ist deine Telefonie-App noch nicht in der Liste bekannter Apps hinterlegt — das lässt sich in der Konfigurationsdatei nachtragen.", "Open the log at `~/CallNotes/log/callwatch.log`. If it mentions an \u{201C}unlisted app\u{201D}, your calling app isn't yet in the list of known apps — this can be added in the config file."))
                    HelpTopic(icon: "speaker.slash", title: L("Gegenseite ist stumm", "Caller is silent"),
                              body_: L("Fast immer die fehlende Systemaudio-Freigabe (siehe oben) — macOS liefert dann Stille statt eines Fehlers. Bei WhatsApp/Discord/Teams hilft manchmal eine Anpassung in der Konfigurationsdatei.", "Almost always the missing system audio permission (see above) — macOS delivers silence instead of an error. For WhatsApp/Discord/Teams, a config file tweak sometimes helps."))
                    HelpTopic(icon: "arrow.clockwise", title: L("Anruf verpasst?", "Missed a call?"),
                              body_: L("Verarbeitungen, die nicht geklappt haben, landen mit dem Roh-Audio im Ordner `~/CallNotes/failed/` und lassen sich von dort erneut anstoßen.", "Processing runs that failed land with the raw audio in `~/CallNotes/failed/` and can be retried from there."))
                    HelpTopic(icon: "checkmark.seal", title: L("Recht", "Legal"),
                              body_: L("Informiere die Gegenseite über die Aufnahme. Die Rechtslage unterscheidet sich je Land — du bist für die rechtmäßige Nutzung verantwortlich.", "Inform the other party about the recording. Laws vary by country — you are responsible for lawful use."))
                }

                HStack {
                    Button(L("Ersteinrichtung erneut starten", "Restart initial setup")) { SetupWizard.shared.show(store: store) }
                        .controlSize(.small)
                    Spacer()
                    Link(L("GitHub & Doku", "GitHub & docs"), destination: URL(string: "https://github.com/michaelczesun/callnotes")!)
                        .font(.caption)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .frame(width: 540, height: 620)
    }
}

// MARK: - Ersteinrichtungs-Assistent

final class SetupWizard {
    static let shared = SetupWizard()
    private var window: NSWindow?

    func show(store: Store) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = NSHostingView(rootView: WizardView(close: { [weak self] in
            self?.window?.close()
            self?.window = nil
        }).environmentObject(store))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = L("CallNotes einrichten", "Set up CallNotes")
        w.contentView = view
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

struct WizardStepHeader: View {
    let step: Int
    let total: Int
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.indigo : Color.primary.opacity(0.12))
                        .frame(height: 4)
                }
            }
            Text(title).font(.title3.weight(.bold))
        }
    }
}

struct WizardView: View {
    @EnvironmentObject var store: Store
    var close: () -> Void
    @State private var step = 0
    @State private var permBusy = false
    @State private var permResult: String?
    @State private var permOk = false
    let total = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case 0:
                WizardStepHeader(step: 0, total: total, title: L("Willkommen bei CallNotes", "Welcome to CallNotes"))
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(accent).frame(width: 64, height: 64)
                        Image(systemName: safeSymbol(["phone.and.waveform.fill", "phone.fill"]))
                            .font(.system(size: 28, weight: .semibold)).foregroundColor(.white)
                    }
                    Text(L("Du telefonierst — CallNotes macht den Rest.", "You take the call — CallNotes handles the rest."))
                        .font(.callout.weight(.medium))
                }
                HStack(spacing: 8) {
                    Text(L("Sprache / Language:", "Language / Sprache:")).font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $store.uiLanguage) {
                        Text("System").tag("system")
                        Text("Deutsch").tag("de")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    .onChange(of: store.uiLanguage) { _ in store.applyLanguageChange() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("Erkennt Anrufe automatisch und nimmt beide Seiten getrennt auf", "Detects calls automatically and records both sides separately"), systemImage: "waveform.badge.mic")
                    Label(L("Transkribiert lokal auf deinem Mac und fasst per KI zusammen", "Transcribes locally on your Mac and summarizes with AI"), systemImage: "cpu")
                    Label(L("Legt die fertige Notiz ab, wo du willst — auch externe Platte, Notes, Notion", "Saves the finished note wherever you like — external drive, Notes, Notion too"), systemImage: "square.and.arrow.down")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            case 1:
                WizardStepHeader(step: 1, total: total, title: L("Freigaben", "Permissions"))
                Text(L("Die Aufnahme übernimmt der Helfer **calltap**. macOS fragt beim ersten Anruf automatisch nach zwei Freigaben — bitte beide erlauben:", "The **calltap** helper handles recording. macOS automatically asks for two permissions on the first call — please allow both:"))
                    .font(.caption).foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("Mikrofon — deine Stimme", "Microphone — your voice"), systemImage: "mic.fill")
                    Label(L("Systemaudio-Aufnahme — die Stimme der Gegenseite", "System audio recording — the caller's voice"), systemImage: "speaker.wave.2.fill")
                }
                .font(.caption)
                // Die Dialoge aktiv ausloesen — erst DANACH taucht calltap ueberhaupt
                // in den Systemeinstellungs-Listen auf (Tester-Feedback 4.7.)
                Button {
                    permBusy = true; permResult = nil
                    DispatchQueue.global().async {
                        // WICHTIG: ueber den launchd-Daemon ausloesen — nur so ist die
                        // TCC-Anfrage calltap.app zugerechnet (ein von HIER gespawntes
                        // calltap wuerde CallNotes als verantwortlichen Prozess erben,
                        // und calltap erschiene nie in den Systemeinstellungs-Listen).
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                        p.arguments = ["kickstart", "-k", "gui/\(getuid())/at.dasgeht.callwatch"]
                        p.standardOutput = Pipe(); p.standardError = Pipe()
                        try? p.run(); p.waitUntilExit()
                        Thread.sleep(forTimeInterval: 6)
                        // Ergebnis aus dem Daemon-Log: Selbsttest laeuft direkt nach Start
                        var ok = false
                        if let log = try? String(contentsOfFile: NSHomeDirectory() + "/CallNotes/log/callwatch.log", encoding: .utf8) {
                            let tail = log.components(separatedBy: "callwatch gestartet").last ?? ""
                            ok = tail.contains("Self-Test: Systemaudio-Tap ok") && !tail.contains("keine Mikrofon-Freigabe")
                        }
                        DispatchQueue.main.async {
                            permBusy = false
                            permOk = ok
                            permResult = ok
                                ? L("Beide Freigaben aktiv — calltap erscheint jetzt auch in den Systemeinstellungen.", "Both permissions active — calltap now also appears in System Settings.")
                                : L("Noch nicht vollständig: eben erschienene macOS-Dialoge erlauben bzw. calltap in beiden Listen aktivieren — dann erneut prüfen.", "Not complete yet: allow the macOS dialogs that just appeared, or enable calltap in both lists — then check again.")
                        }
                    }
                } label: {
                    if permBusy { ProgressView().controlSize(.small) } else { Text(L("Freigaben jetzt anfordern & prüfen", "Request & check permissions now")) }
                }
                .disabled(permBusy)
                if let r = permResult {
                    Text(r).font(.caption2).foregroundColor(permOk ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("Kam kein Dialog oder ist die Gegenseite später stumm, findest du beides hier:", "If there's no dialogue or the caller is silent later, find both settings here:"))
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Button(L("Mikrofon-Einstellungen öffnen", "Open microphone settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }.controlSize(.small)
                    Button(L("Systemaudio-Einstellungen öffnen", "Open system audio settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }.controlSize(.small)
                }
            case 2:
                WizardStepHeader(step: 2, total: total, title: L("Speicherorte", "Storage locations"))
                Text(L("Wohin sollen Notizen und Audio? (Später jederzeit änderbar — Kopie ist z. B. deine externe Festplatte.)", "Where should notes and audio go? (Changeable anytime later — the mirror is e.g. your external drive.)"))
                    .font(.caption).foregroundColor(.secondary)
                PathRow(label: L("Notizen", "Notes"), path: $store.notesDir,
                        info: L("Zielordner der fertigen Markdown-Notizen. Ideal: dein Obsidian-Vault — dann sind Anrufe sofort verlinkbar.", "Destination folder for the finished markdown notes. Ideal: your Obsidian vault — then calls are instantly linkable."))
                PathRow(label: L("Audio-Archiv", "Audio archive"), path: $store.audioDir,
                        info: L("Je Anruf eine m4a-Datei: links dein Mikro, rechts die Gegenseite.", "One m4a file per call: your mic on the left, the caller on the right."))
                PathRow(label: L("Kopie (extern)", "Mirror (external)"), path: $store.mirrorDir, clearable: true,
                        info: L("Optionaler Spiegel-Ordner, z. B. auf der externen Platte. Wird nach jedem Anruf synchronisiert; ist die Platte nicht angeschlossen, wird später automatisch nachgeholt.", "Optional mirror folder, e.g. on an external drive. Synced after every call; if the drive isn't connected, it's caught up automatically later."))
            case 3:
                WizardStepHeader(step: 3, total: total, title: L("Transkription & KI", "Transcription & AI"))
                Text(L("Wo soll transkribiert werden?", "Where should transcription happen?")).font(.caption).foregroundColor(.secondary)
                Picker("", selection: $store.transcriber) {
                    Text("Whisper").tag("local")
                    Text("Parakeet").tag("parakeet")
                    Text(L("Groq API", "Groq API")).tag("groq")
                }
                .pickerStyle(.segmented).labelsHidden()
                if store.transcriber == "groq" {
                    SecureField(L("Groq API-Key (console.groq.com)", "Groq API key (console.groq.com)"), text: $store.groqApiKey)
                        .textFieldStyle(.roundedBorder).font(.caption)
                }
                Text(L("Was soll in der Notiz stehen?", "What should the note contain?")).font(.caption).foregroundColor(.secondary).padding(.top, 4)
                HStack {
                    wToggle(L("Kurzfassung", "Summary"), "kurzfassung")
                    wToggle(L("Besprochen", "Discussed"), "besprochen")
                }
                HStack {
                    wToggle(L("To-dos", "To-dos"), "todos")
                    wToggle(L("Follow-up-Mail", "Follow-up email"), "followup")
                }
            default:
                WizardStepHeader(step: 4, total: total, title: L("Fertig!", "All set!"))
                HStack(spacing: 6) {
                    Circle().fill(store.daemonRunning ? Color.green : Color.orange).frame(width: 9, height: 9)
                    Text(store.daemonRunning ? L("Der Anruf-Autopilot läuft.", "The call autopilot is running.") : L("Autopilot wird beim Abschluss gestartet.", "The autopilot starts once you finish."))
                        .font(.callout.weight(.medium))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("Mach jetzt einen **Testanruf** (länger als 20 Sekunden)", "Make a **test call** now (longer than 20 seconds)"), systemImage: "phone.arrow.up.right")
                    Label(L("Beim ersten Mal die macOS-Freigaben erlauben", "Allow the macOS permissions the first time"), systemImage: "lock.open")
                    Label(L("~1 Minute nach dem Auflegen liegt die Notiz im Notizen-Ordner", "~1 minute after hanging up, the note appears in the notes folder"), systemImage: "doc.text")
                    Label(L("Alles Weitere: ? in der Menüleiste → Hilfe", "For everything else: ? in the menu bar → Help"), systemImage: "questionmark.circle")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
            HStack {
                if step > 0 {
                    Button(L("Zurück", "Back")) { step -= 1 }.controlSize(.small)
                }
                Spacer()
                if step < total - 1 {
                    Button(L("Weiter", "Next")) { step += 1 }
                        .buttonStyle(.borderedProminent).tint(.indigo)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Einrichtung abschließen", "Finish setup")) {
                        store.setupDone = true
                        store.saveAndRestart()
                        close()
                    }
                    .buttonStyle(.borderedProminent).tint(.indigo)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 520, height: 480)
    }

    func wToggle(_ label: String, _ key: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { store.sections.contains(key) },
            set: { on in if on { store.sections.insert(key) } else { store.sections.remove(key) } }
        ))
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Bausteine

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

extension View {
    func hoverHighlight() -> some View {
        self.contentShape(Rectangle()).background(HoverHighlight())
    }
}

struct HoverHighlight: View {
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            .onHover { hovering = $0 }
    }
}

struct WaveRow: View {
    let label: String
    let color: Color
    let levels: [Double]

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(width: 66, alignment: .leading)
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(color.opacity(0.55 + v * 0.45))
                        .frame(width: 3, height: max(3, v * 26))
                }
            }
            .frame(height: 28, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(.linear(duration: 0.3), value: levels)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("\(label) Lautstärke", "\(label) volume"))
            .accessibilityValue(levels.last.map { Int($0 * 100).description + L(" Prozent", " percent") } ?? L("still", "silent"))
        }
    }
}

struct ParticipantFieldsView: View {
    @EnvironmentObject var store: Store
    @FocusState private var focusedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.participantFields.indices, id: \.self) { i in
                HStack {
                    Image(systemName: "person.crop.circle").foregroundColor(.secondary)
                    TextField(L("Name Teilnehmer \(i + 1)", "Participant \(i + 1) name"), text: Binding(
                        get: { i < store.participantFields.count ? store.participantFields[i] : "" },
                        set: { if i < store.participantFields.count { store.participantFields[i] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedIndex, equals: i)
                    if store.participantFields.count > 1 {
                        Button {
                            if i < store.participantFields.count { store.participantFields.remove(at: i) }
                        } label: { Image(systemName: "minus.circle.fill").foregroundColor(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Button { store.participantFields.append("") } label: {
                    Label(L("weiterer Teilnehmer", "add participant"), systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                InfoTip(title: L("Teilnehmer", "Participants"),
                        text: L("Wer ist im Gespräch? Die Namen helfen der KI bei der Zusammenfassung und stehen nach Konferenzen im Zuordnungs-Dropdown bereit. Optional — geht auch ohne.", "Who's in the call? The names help the AI with the summary and are ready in the assignment dropdown after conference calls. Optional — works without it too."))
                Spacer()
                Button(store.participantsSaved ? L("Gespeichert ✓", "Saved ✓") : L("Speichern", "Save")) { store.saveParticipants() }
                    .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            Divider()
            HStack(spacing: 4) {
                Button { store.abortRecording() } label: {
                    Label(L("Diesen Anruf nicht aufnehmen", "Don't record this call"), systemImage: "mic.slash.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .hoverHighlight()
                InfoTip(title: L("Nicht aufnehmen", "Don't record"),
                        text: L("Verwirft die laufende Aufnahme sofort und unwiderruflich — es wird nichts gespeichert oder verarbeitet. Für diesen Anruf startet die Aufnahme auch nicht neu; ab dem nächsten Anruf ist der Autopilot wieder aktiv.", "Discards the current recording immediately and irreversibly — nothing is saved or processed. Recording won't restart for this call either; the autopilot is active again from the next call on."))
                Spacer()
            }
        }
        .onAppear { focusedIndex = 0 }
    }
}

struct CallPopupView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(accent).frame(width: 28, height: 28)
                    Image(systemName: safeSymbol(["phone.and.waveform.fill", "phone.fill"]))
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Anruf erkannt", "Call detected")).fontWeight(.semibold)
                    Text(L("via \(store.currentCall?.appName ?? "?") — wer ist dran?", "via \(store.currentCall?.appName ?? "?") — who's on the line?"))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            ParticipantFieldsView()
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct PendingView: View {
    @EnvironmentObject var store: Store
    let p: PendingCall
    @State private var justApplied = false

    var body: some View {
        Card {
            HStack {
                Image(systemName: "person.2.wave.2.fill").foregroundColor(.indigo)
                Text(L("\(p.speakers.count) Stimmen · \(p.app) · \(p.stamp)", "\(p.speakers.count) voices · \(p.app) · \(p.stamp)"))
                    .font(.caption).foregroundColor(.secondary)
                InfoTip(title: L("Stimmen zuordnen", "Assign voices"),
                        text: L("Auf der Gegenseite wurden mehrere Stimmen erkannt. ▶︎ spielt eine Hörprobe der jeweiligen Person; wähle dann den Namen im Dropdown (Vorschläge kommen aus dem Gespräch). „Zuordnung übernehmen\u{201C} schreibt die Namen ins Transkript der Notiz.", "Multiple voices were detected on the other end. ▶︎ plays a voice sample for that person; then pick the name from the dropdown (suggestions come from the conversation). \u{201C}Apply names\u{201D} writes the names into the note's transcript."))
                Spacer()
            }
            ForEach(p.speakers) { s in
                let k = store.key(p, s)
                HStack(spacing: 8) {
                    Button { store.playClip(s.clip) } label: {
                        Image(systemName: "play.circle.fill").font(.title2).foregroundColor(.indigo)
                    }
                    .buttonStyle(.plain)
                    .help(L("Hörprobe \(s.label) (\(Int(s.totalSec))s Redezeit)", "Voice sample \(s.label) (\(Int(s.totalSec))s talk time)"))
                    Text(s.label).font(.callout).frame(width: 74, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { store.picks[k] ?? kKeep },
                        set: { store.picks[k] = $0 }
                    )) {
                        ForEach(store.options(for: p, s), id: \.self) { Text($0) }
                    }
                    .labelsHidden()
                }
                if store.picks[k] == kCustom {
                    TextField(L("Name eingeben", "Enter name"), text: Binding(
                        get: { store.customNames[k] ?? "" },
                        set: { store.customNames[k] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 36)
                }
            }
            HStack {
                Button(L("Notiz ansehen", "View note")) { NSWorkspace.shared.open(URL(fileURLWithPath: p.note)) }
                    .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                    .padding(.vertical, 3).padding(.horizontal, 4)
                    .hoverHighlight()
                Spacer()
                Button(L("Zuordnung übernehmen", "Apply names")) {
                    justApplied = true
                    store.apply(p)
                }
                    .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.small)
            }
            if justApplied {
                Text(L("Wird übernommen …", "Applying …")).font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}

struct PathRow: View {
    let label: String
    @Binding var path: String
    var clearable = false
    var info = ""

    var body: some View {
        HStack {
            HStack(spacing: 3) {
                Text(label).font(.caption)
                if !info.isEmpty { InfoTip(title: label, text: info) }
            }
            .frame(width: 108, alignment: .leading)
            Text(path.isEmpty ? L("— aus —", "— off —") : tilde(path))
                .font(.caption)
                .lineLimit(1).truncationMode(.middle)
                .foregroundColor(path.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if clearable && !path.isEmpty {
                Button(L("aus", "off")) { path = "" }.font(.caption).buttonStyle(.plain).foregroundColor(.secondary)
            }
            Button(L("wählen…", "choose…")) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = L("Auswählen", "Choose")
                if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: untilde(path)) }
                if panel.runModal() == .OK, let url = panel.url { path = tilde(url.path) }
            }
            .font(.caption).controlSize(.small)
        }
    }
}

struct SettingsSection: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 3) {
                Text(L("SPRACHE", "LANGUAGE")).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                InfoTip(title: L("Sprache", "Language"),
                        text: L("System folgt deiner macOS-Sprache. Beim Wechsel startet die App kurz neu — Einstellungen bleiben erhalten.", "System follows your macOS language. Switching restarts the app briefly — settings are preserved."))
            }
            Picker("", selection: $store.uiLanguage) {
                Text("System").tag("system")
                Text("Deutsch").tag("de")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: store.uiLanguage) { _ in store.applyLanguageChange() }

            Text(L("SPEICHERORTE", "STORAGE LOCATIONS")).font(.caption2.weight(.bold)).foregroundColor(.secondary).padding(.top, 4)
            PathRow(label: L("Notizen", "Notes"), path: $store.notesDir,
                    info: L("Zielordner der fertigen Markdown-Notizen. Ideal: dein Obsidian-Vault — dann sind Anrufe sofort verlinkbar.", "Destination folder for the finished markdown notes. Ideal: your Obsidian vault — then calls are instantly linkable."))
            PathRow(label: L("Audio-Archiv", "Audio archive"), path: $store.audioDir,
                    info: L("Je Anruf eine m4a-Datei: links dein Mikro, rechts die Gegenseite.", "One m4a file per call: your mic on the left, the caller on the right."))
            PathRow(label: L("Kopie (extern)", "Mirror (external)"), path: $store.mirrorDir, clearable: true,
                    info: L("Optionaler Spiegel-Ordner, z. B. externe Festplatte. Wird nach jedem Anruf synchronisiert; ist die Platte nicht dran, wird automatisch nachgeholt. Beim ersten Mal fragt macOS nach der Wechseldatenträger-Freigabe.", "Optional mirror folder, e.g. an external drive. Synced after every call; if the drive isn't connected, it's caught up automatically. The first time, macOS asks for removable-volume access."))

            HStack(spacing: 3) {
                Text(L("TRANSKRIPTION", "TRANSCRIPTION")).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                InfoTip(title: L("Transkription", "Transcription"),
                        text: L("Whisper = whisper.cpp lokal: offline, privat, bewährt. Parakeet = NVIDIA Parakeet TDT v3 lokal via sherpa-onnx: die schnellste Option, 25 EU-Sprachen, keine Halluzinations-Schleifen (einmalig ~700 MB: ./install.sh --with-parakeet). Groq = Cloud-API — schnell, aber das Audio verlässt deinen Mac.", "Whisper = whisper.cpp locally: offline, private, proven. Parakeet = NVIDIA Parakeet TDT v3 locally via sherpa-onnx: the fastest option, 25 EU languages, no hallucination loops (one-time ~700 MB: ./install.sh --with-parakeet). Groq = cloud API — fast, but the audio leaves your Mac."))
            }
            .padding(.top, 4)
            Picker("", selection: $store.transcriber) {
                Text("Whisper").tag("local")
                Text("Parakeet").tag("parakeet")
                Text("Groq API").tag("groq")
            }
            .pickerStyle(.segmented).labelsHidden()
            if store.transcriber == "groq" {
                HStack(spacing: 4) {
                    SecureField(L("Groq API-Key (gsk_…)", "Groq API key (gsk_…)"), text: $store.groqApiKey)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    InfoTip(title: L("Groq API-Key", "Groq API key"),
                            text: L("Gratis auf console.groq.com erstellen. Der Key wird nur lokal gespeichert (~/.config/callnotes) und nie hochgeladen.", "Create one for free at console.groq.com. The key is stored locally only (~/.config/callnotes) and never uploaded."))
                }
            }

            HStack(spacing: 3) {
                Text(L("KI-ZUSAMMENFASSUNG", "AI SUMMARY")).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                InfoTip(title: L("KI-Zusammenfassung", "AI summary"),
                        text: L("Wer schreibt Kurzfassung & To-dos? Claude Code nutzt dein bestehendes Claude-Abo (Standard). „Eigene KI\u{201C} spricht jede OpenAI-kompatible API — OpenAI, Groq, OpenRouter oder komplett lokal via Ollama. „Aus\u{201C} = Notiz nur mit Transkript.", "Who writes the summary & to-dos? Claude Code uses your existing Claude subscription (default). \u{201C}Custom AI\u{201D} talks to any OpenAI-compatible API — OpenAI, Groq, OpenRouter, or fully local via Ollama. \u{201C}Off\u{201D} = note with transcript only."))
            }
            .padding(.top, 4)
            Picker("", selection: $store.summarizer) {
                Text("Claude Code").tag("claude")
                Text(L("Eigene KI (OpenAI-API)", "Custom AI (OpenAI API)")).tag("openai")
                Text(L("Aus", "Off")).tag("off")
            }
            .pickerStyle(.segmented).labelsHidden()
            if store.summarizer == "openai" {
                HStack(spacing: 4) {
                    TextField(L("API-URL, z. B. https://api.openai.com/v1", "API URL, e.g. https://api.openai.com/v1"), text: $store.sumUrl)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    InfoTip(title: L("API-URL", "API URL"),
                            text: L("Basis-URL der OpenAI-kompatiblen API:\nOpenAI: https://api.openai.com/v1\nGroq: https://api.groq.com/openai/v1\nOpenRouter: https://openrouter.ai/api/v1\nOllama (lokal, kostenlos): http://localhost:11434/v1", "Base URL of the OpenAI-compatible API:\nOpenAI: https://api.openai.com/v1\nGroq: https://api.groq.com/openai/v1\nOpenRouter: https://openrouter.ai/api/v1\nOllama (local, free): http://localhost:11434/v1"))
                }
                HStack {
                    TextField(L("Modell, z. B. gpt-4o-mini", "Model, e.g. gpt-4o-mini"), text: $store.sumModel)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    SecureField(L("API-Key (bei Ollama leer)", "API key (leave empty for Ollama)"), text: $store.sumKey)
                        .textFieldStyle(.roundedBorder).font(.caption)
                }
            }

            HStack(spacing: 3) {
                Text(L("NOTIZ-INHALTE", "NOTE CONTENTS")).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                InfoTip(title: L("Notiz-Inhalte", "Note contents"),
                        text: L("Welche Abschnitte die KI in die Notiz schreibt. Follow-up-Mail = fertiger Entwurf an die Gegenseite (Dank, Vereinbartes, nächste Schritte). Das Transkript ist immer enthalten.", "Which sections the AI writes into the note. Follow-up email = ready-to-send draft to the caller (thanks, agreements, next steps). The transcript is always included."))
            }
            .padding(.top, 4)
            HStack {
                sectionToggle(L("Kurzfassung", "Summary"), "kurzfassung")
                sectionToggle(L("Besprochen", "Discussed"), "besprochen")
            }
            HStack {
                sectionToggle(L("To-dos", "To-dos"), "todos")
                sectionToggle(L("Follow-up-Mail", "Follow-up email"), "followup")
            }

            Text(L("ABLAGE ZUSÄTZLICH IN", "ALSO SAVE TO")).font(.caption2.weight(.bold)).foregroundColor(.secondary).padding(.top, 4)
            HStack(spacing: 4) {
                Toggle(L("Apple Notes (Ordner „CallNotes\u{201C})", "Apple Notes (\u{201C}CallNotes\u{201D} folder)"), isOn: $store.destNotes).font(.caption)
                InfoTip(title: "Apple Notes",
                        text: L("Legt jede Notiz zusätzlich in Apple Notes ab (Ordner „CallNotes\u{201C}). Beim ersten Anruf fragt macOS nach einer Automation-Freigabe — erlauben.", "Also saves every note to Apple Notes (\u{201C}CallNotes\u{201D} folder). On the first call, macOS asks for an Automation permission — allow it."))
                Spacer()
            }
            HStack(spacing: 4) {
                Toggle("Nextcloud", isOn: $store.destNextcloud.animation(.easeInOut(duration: 0.18))).font(.caption)
                InfoTip(title: "Nextcloud",
                        text: L("Lädt die Notiz per WebDAV in deine Cloud (Ordner „CallNotes\u{201C}). App-Passwort in Nextcloud unter Einstellungen → Sicherheit erzeugen — nicht dein Login-Passwort verwenden.", "Uploads the note via WebDAV to your cloud (\u{201C}CallNotes\u{201D} folder). Create an app password in Nextcloud under Settings → Security — don't use your login password."))
                Spacer()
            }
            if store.destNextcloud {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L("Nextcloud-URL (https://…)", "Nextcloud URL (https://…)"), text: $store.ncUrl).textFieldStyle(.roundedBorder).font(.caption)
                    HStack {
                        TextField(L("Benutzer", "Username"), text: $store.ncUser).textFieldStyle(.roundedBorder).font(.caption)
                        SecureField(L("App-Passwort", "App password"), text: $store.ncPass).textFieldStyle(.roundedBorder).font(.caption)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 4) {
                Toggle("Notion", isOn: $store.destNotion.animation(.easeInOut(duration: 0.18))).font(.caption)
                InfoTip(title: "Notion",
                        text: L("Erstellt je Anruf eine Unterseite. Integration auf notion.so/my-integrations anlegen, Token hier eintragen und die Ziel-Seite über ••• → Verbindungen für die Integration freigeben. Seiten-ID = die 32 Zeichen aus der Seiten-URL.", "Creates a subpage for each call. Create an integration at notion.so/my-integrations, paste the token here, and share the target page with the integration via ••• → Connections. Page ID = the 32 characters from the page URL."))
                Spacer()
            }
            if store.destNotion {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField(L("Notion Integration-Token (ntn_/secret_…)", "Notion integration token (ntn_/secret_…)"), text: $store.notionToken).textFieldStyle(.roundedBorder).font(.caption)
                    TextField(L("Seiten-ID oder Seiten-URL-ID", "Page ID or page URL ID"), text: $store.notionParent).textFieldStyle(.roundedBorder).font(.caption)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 3) {
                Text(L("PUSH", "PUSH")).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                InfoTip(title: L("ntfy-Push", "ntfy push"),
                        text: L("Kostenlose Push-Nachricht aufs Handy nach jeder fertigen Notiz: ntfy.sh-App installieren, ein Thema abonnieren und hier die URL eintragen (https://ntfy.sh/dein-thema).", "Free push notification to your phone after every finished note: install the ntfy.sh app, subscribe to a topic, and enter the URL here (https://ntfy.sh/your-topic)."))
            }
            .padding(.top, 4)
            TextField(L("ntfy.sh-URL (optional)", "ntfy.sh URL (optional)"), text: $store.ntfyUrl).textFieldStyle(.roundedBorder).font(.caption)

            HStack {
                Button(L("Jetzt syncen", "Sync now")) { store.syncNow() }
                    .controlSize(.small).disabled(store.mirrorDir.isEmpty)
                Spacer()
                Button(L("Speichern & Neustart", "Save & restart")) { store.saveAndRestart() }
                    .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.small)
            }
            .padding(.top, 2)
        }
    }

    func sectionToggle(_ label: String, _ key: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { store.sections.contains(key) },
            set: { on in if on { store.sections.insert(key) } else { store.sections.remove(key) } }
        ))
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuPanelView: View {
    @EnvironmentObject var store: Store
    @State private var showSettings: Bool
    private let unlimited: Bool

    init(startWithSettings: Bool = false, unlimited: Bool = false) {
        _showSettings = State(initialValue: startWithSettings)
        self.unlimited = unlimited
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(accent).frame(width: 32, height: 32)
                    Image(systemName: safeSymbol(["phone.and.waveform.fill", "phone.fill"]))
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("CallNotes").font(.title3.weight(.bold))
                    Text(store.currentCall != nil ? L("Aufnahme läuft", "Recording in progress") : (store.daemonRunning ? L("Anruf-Autopilot bereit", "Call autopilot ready") : L("Anruf-Autopilot AUS", "Call autopilot OFF")))
                        .font(.caption)
                        .foregroundColor(store.currentCall != nil ? .indigo : (store.daemonRunning ? .secondary : .orange))
                }
                Spacer()
                Button { HelpWindow.shared.show(store: store) } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Hilfe & Erklärungen", "Help & explanations"))
                Circle()
                    .fill(store.currentCall != nil ? Color.indigo : (store.daemonRunning ? Color.green : Color.orange))
                    .frame(width: 9, height: 9)
            }

            // Laufender Anruf: Live-Spuren + Teilnehmer
            if let call = store.currentCall {
                Card {
                    HStack {
                        Image(systemName: "record.circle").foregroundColor(.red)
                        Text("\(call.appName) · \(store.callElapsed)").font(.callout.weight(.semibold))
                        Spacer()
                    }
                    WaveRow(label: L("Du", "You"), color: .indigo, levels: store.micLevels)
                    WaveRow(label: L("Gegenseite", "Caller"), color: .pink, levels: store.sysLevels)
                    Divider()
                    ParticipantFieldsView()
                }
            }

            // Verarbeitung nach dem Auflegen
            if let phase = store.processingPhase {
                Card {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(phase).font(.callout)
                        Spacer()
                    }
                }
            }

            // Leerlauf: Erstnutzern erklaeren, WANN etwas passiert (Popup kommt
            // erst im laufenden Anruf, nicht schon beim Oeffnen der Call-App)
            if store.currentCall == nil && store.processingPhase == nil && store.pendings.isEmpty {
                Card {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: safeSymbol(["waveform.badge.magnifyingglass", "waveform"]))
                            .foregroundColor(.secondary)
                        Text(store.daemonRunning
                             ? L("Bereit. Sobald in einer Call-App wirklich ein Anruf läuft (Mikrofon aktiv), startet die Aufnahme von selbst und ein Popup erscheint. Die App nur zu öffnen reicht nicht.",
                                 "Ready. As soon as a call is actually running in a call app (microphone active), recording starts by itself and a popup appears. Just opening the app is not enough.")
                             : L("Der Aufnahme-Dienst läuft nicht. Einmal ./install.sh im Repo ausführen oder den Mac neu starten.",
                                 "The recording service is not running. Run ./install.sh in the repo once, or restart your Mac."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Sprecher-Zuordnung
            if !store.pendings.isEmpty {
                ForEach(store.pendings) { p in PendingView(p: p) }
            }

            // Fehlgeschlagene Verarbeitungen: sichtbar machen statt still liegen lassen
            if store.failedCount > 0 {
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(L("\(store.failedCount) Aufnahme\(store.failedCount == 1 ? "" : "n") nicht verarbeitet", "\(store.failedCount) recording\(store.failedCount == 1 ? "" : "s") not processed"))
                            .font(.callout)
                        InfoTip(title: L("Nicht verarbeitet", "Not processed"),
                                text: L("Diese Anrufe wurden aufgenommen, aber die Verarbeitung schlug fehl (z. B. Whisper-Modell fehlte, Absturz — oder die Aufnahme ist leer). „Erneut versuchen\u{201C} startet die Verarbeitung nochmal; schlägt sie wieder fehl, ist die Aufnahme vermutlich unbrauchbar → „Verwerfen\u{201C} löscht sie endgültig.", "These calls were recorded, but processing failed (e.g. missing Whisper model, a crash — or the recording is empty). \u{201C}Retry\u{201D} runs processing again; if it fails again, the recording is likely unusable → \u{201C}Discard\u{201D} deletes it for good."))
                        Spacer()
                        Button(L("Verwerfen", "Discard")) { store.discardFailed() }
                            .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                            .padding(.vertical, 3).padding(.horizontal, 4)
                            .hoverHighlight()
                        Button(L("Erneut versuchen", "Retry")) { store.retryFailed() }
                            .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                    }
                }
            }

            // Sanfter Update-Hinweis (neues GitHub-Release)
            if let v = store.updateAvailable {
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundColor(.indigo)
                        Text(L("Version \(v) ist verfügbar", "Version \(v) available")).font(.callout)
                        InfoTip(title: "Update",
                                text: L("Aktualisieren im Terminal: in den callnotes-Ordner wechseln, dann git pull && ./install.sh — deine Einstellungen bleiben erhalten.", "To update in Terminal: cd into the callnotes folder, then run git pull && ./install.sh — your settings are preserved."))
                        Spacer()
                        Button(L("Ansehen", "View")) { NSWorkspace.shared.open(URL(string: kRepoURL + "/releases/latest")!) }
                            .controlSize(.small)
                    }
                }
            }

            // Leerzustand: noch nichts passiert
            if store.currentCall == nil && store.processingPhase == nil && store.pendings.isEmpty && store.lastNotes.isEmpty {
                Card {
                    VStack(spacing: 6) {
                        Image(systemName: "phone.and.waveform")
                            .font(.title2)
                            .foregroundColor(.secondary.opacity(0.5))
                        Text(L("Noch keine Anrufe aufgezeichnet", "No calls recorded yet"))
                            .font(.caption).foregroundColor(.secondary)
                        Text(L("Sobald du telefonierst, erscheint hier die Live-Aufnahme.", "As soon as you're on a call, the live recording appears here."))
                            .font(.caption2).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // Letzte Anrufe
            if !store.lastNotes.isEmpty {
                Card {
                    Text(L("LETZTE ANRUFE", "RECENT CALLS")).font(.caption2.weight(.bold)).foregroundColor(.secondary)
                    ForEach(store.lastNotes, id: \.self) { n in
                        Button { store.openNote(n) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").foregroundColor(.indigo)
                                Text(n).font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.caption2).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 4)
                            .hoverHighlight()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().padding(.vertical, 2)

            // Einstellungen
            DisclosureGroup(isExpanded: $showSettings) {
                SettingsSection().padding(.top, 6)
            } label: {
                Label(L("Einstellungen", "Settings"), systemImage: "gearshape.fill")
                    .font(.callout.weight(.medium))
            }

            HStack {
                if !store.status.isEmpty {
                    Text(store.status).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button(L("Beenden", "Quit")) { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                    .padding(.vertical, 3).padding(.horizontal, 4)
                    .hoverHighlight()
            }
        }
        .padding(14)
        .frame(width: 400)
        }
        .frame(maxHeight: unlimited ? .infinity : 620)
    }
}

// MARK: - Schaufenster-Fenster fuer README-Screenshots

final class ShowcaseWindow {
    static var window: NSWindow?

    static func show(store: Store, mode: String) {
        NSApp.appearance = NSAppearance(named: .darkAqua) // Screenshots immer im Dark Mode
        let root = MenuPanelView(startWithSettings: mode == "settings", unlimited: true)
            .environmentObject(store)
            .background(Color(nsColor: .windowBackgroundColor))
        let hc = NSHostingController(rootView: root)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
                         styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.hasShadow = false
        w.isOpaque = true
        w.backgroundColor = NSColor.windowBackgroundColor
        w.contentViewController = hc
        let size = hc.view.fittingSize
        w.setContentSize(NSSize(width: 400, height: max(size.height, 300)))
        w.setFrameOrigin(NSPoint(x: 120, y: 160))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        // Selbst-Render statt screencapture (keine Bildschirmaufnahme-Freigabe noetig):
        // CALLNOTES_SHOT=/pfad.png -> Fenster als PNG schreiben und beenden.
        if let shotPath = ProcessInfo.processInfo.environment["CALLNOTES_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard let view = w.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: shotPath))
                }
                NSApp.terminate(nil)
            }
        }
    }
}

// Doppelklick im Finder auf die laufende Menueleisten-App: statt "nichts passiert"
// das Panel als normales Fenster zeigen (Tester-Feedback: "App laesst sich nicht oeffnen").
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let s = Store.shared { StandalonePanel.shared.show(store: s) }
        return false
    }
}

final class StandalonePanel {
    static let shared = StandalonePanel()
    private var window: NSWindow?

    func show(store: Store) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let root = VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: safeSymbol(["menubar.arrow.up.rectangle", "arrow.up.right.circle"]))
                Text(L("CallNotes wohnt oben in der Menüleiste (Telefon-Symbol) — dieses Fenster zeigt dieselbe Ansicht.",
                       "CallNotes lives in the menu bar (phone icon, top right) — this window shows the same view."))
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            MenuPanelView(unlimited: true).environmentObject(store)
        }
        // ScrollView hat keine intrinsische Hoehe — ohne festen Frame kollabiert
        // das Fenster auf die Kopfzeile (Tester-/Michael-Screenshot 4.7.)
        .frame(width: 400, height: 660)
        let hc = NSHostingController(rootView: root)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "CallNotes"
        w.contentViewController = hc
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

// MARK: - App

@main
struct CallNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store(showcase: ProcessInfo.processInfo.environment["CALLNOTES_SHOWCASE"])

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView().environmentObject(store)
        } label: {
            Image(systemName: menuSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    var menuSymbol: String {
        if store.currentCall != nil { return safeSymbol(["phone.connection.fill", "phone.fill"]) }
        if !store.pendings.isEmpty { return safeSymbol(["phone.badge.checkmark", "phone.fill"]) }
        return safeSymbol(["phone.and.waveform.fill", "phone.badge.waveform", "phone.fill"])
    }
}
