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

func tilde(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

func untilde(_ p: String) -> String { NSString(string: p).expandingTildeInPath }

func safeSymbol(_ candidates: [String]) -> String {
    for n in candidates where NSImage(systemSymbolName: n, accessibilityDescription: nil) != nil { return n }
    return "phone.fill"
}

let kKeep = "— Label behalten —"
let kCustom = "Eigener Name…"
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
    // Laufzeit
    @Published var status = ""
    @Published var daemonRunning = false
    @Published var lastNotes: [String] = []
    @Published var failedCount = 0
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
    var setupDone = true

    private var raw: [String: Any] = [:]
    private var baseDir = untilde("~/CallNotes")
    private var scriptDir = ""
    private var timer: Timer?
    private var levelTimer: Timer?
    private var player: AVAudioPlayer?
    private var poppedFor = ""
    private var tick = 0

    init() {
        load()
        poll()
        // .common-Mode: weiterlaufen, auch wenn ein Menue/Drag die RunLoop im Tracking haelt
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if !setupDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.setupDone else { return }
                SetupWizard.shared.show(store: self)
            }
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
            setupDone = obj["setupDone"] as? Bool ?? false
            baseDir = untilde(obj["outDir"] as? String ?? "~/CallNotes")
            if let post = obj["postScript"] as? String {
                scriptDir = (untilde(post) as NSString).deletingLastPathComponent
            }
        } else {
            status = "Keine Config — install.sh ausführen."
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
        status = "Aufnahme wird verworfen — dieser Anruf bleibt privat."
        CallPopupPanel.shared.hide()
    }

    func saveParticipants() {
        guard let call = currentCall else { return }
        let names = participantFields.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let d = try? JSONSerialization.data(withJSONObject: ["names": names], options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: call.dir + "/participants.json"))
            participantsSaved = true
            status = names.isEmpty ? "Teilnehmer geleert" : "Teilnehmer: \(names.joined(separator: ", "))"
        }
        CallPopupPanel.shared.hide()
    }

    func playClip(_ path: String) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        if player == nil { status = "Hörprobe nicht mehr verfügbar." }
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
        guard FileManager.default.fileExists(atPath: script) else { status = "apply-speakers.sh fehlt"; return }
        status = "Übernehme Zuordnung …"
        let mapping = parts.joined(separator: ";")
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let (code, out) = self.run(["/bin/bash", script, p.path, mapping])
            DispatchQueue.main.async {
                self.status = code == 0 ? "✅ Zuordnung übernommen" : "❌ Zuordnung fehlgeschlagen: \(out.suffix(140))"
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

    // Fehlgeschlagene Verarbeitungen (Roh-Audio liegt in failed/) erneut anstossen
    func retryFailed() {
        let dir = baseDir + "/failed"
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { !$0.hasPrefix(".") }
        guard !items.isEmpty else { return }
        let script = scriptDir + "/process-call.sh"
        guard FileManager.default.fileExists(atPath: script) else { status = "process-call.sh fehlt"; return }
        status = "Nachverarbeitung von \(items.count) Aufnahme(n) gestartet …"
        let logFile = baseDir + "/log/process.log"
        for it in items {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "nohup /bin/bash '\(script)' '\(dir)/\(it)' >> '\(logFile)' 2>&1 &"]
            try? p.run()
        }
    }

    func openNote(_ name: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: untilde(notesDir) + "/" + name))
    }

    func saveAndRestart() {
        guard persist() else { status = "❌ Config nicht schreibbar"; return }
        let (code, out) = run(["/bin/launchctl", "kickstart", "-k", "gui/\(getuid())/at.dasgeht.callwatch"])
        refreshDaemon()
        status = code == 0 ? "✅ Gespeichert & Daemon neu gestartet" : "⚠️ \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func syncNow() {
        guard persist() else { status = "❌ Config nicht schreibbar"; return }
        guard !mirrorDir.isEmpty else { status = "Kein Kopie-Ordner gewählt."; return }
        let script = scriptDir + "/callnotes-sync.sh"
        guard FileManager.default.fileExists(atPath: script) else { status = "❌ Sync-Skript fehlt"; return }
        status = "Kopiere …"
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let (code, out) = self.run(["/bin/bash", script])
            DispatchQueue.main.async {
                self.status = code == 0 ? "✅ Kopiert nach \(tilde(self.mirrorDir))" : "❌ Kopieren fehlgeschlagen: \(out.suffix(140))"
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
        .accessibilityLabel("Erklärung: \(title)")
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
        w.title = "CallNotes — Hilfe"
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
                        Text("CallNotes Hilfe").font(.title3.weight(.bold))
                        Text("Alles Wichtige zum Einstellen und Nutzen").font(.caption).foregroundColor(.secondary)
                    }
                }

                Group {
                    Text("SO FUNKTIONIERT ES").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                    HelpTopic(icon: "waveform.badge.mic", title: "Automatische Aufnahme",
                              body_: "Sobald eine Telefonie-App (FaceTime, iPhone-Anruf, WhatsApp, Zoom, Teams, Signal, Telegram, Discord) dein Mikrofon nutzt, startet die Aufnahme — zwei getrennte Spuren: dein Mikro und der Ton der Gegenseite. Nach dem Auflegen stoppt sie von selbst; Anrufe unter 20 Sekunden werden verworfen.")
                    HelpTopic(icon: "doc.text", title: "Die fertige Notiz",
                              body_: "Etwa eine Minute nach dem Auflegen liegt die Notiz im Notizen-Ordner: KI-Kurzfassung, besprochene Punkte, Zusagen & To-dos und das komplette Dialog-Transkript mit Sprechern. Dazu ein Audio-Archiv als m4a (links du, rechts Gegenseite).")
                    HelpTopic(icon: "person.2.wave.2", title: "Konferenzen & Sprecher-Zuordnung",
                              body_: "Bei mehreren Stimmen auf der Gegenseite trennt die lokale Sprecher-Erkennung sie in „Sprecher 1..N\u{201C}. Im Menüleisten-Panel erscheint dann „Stimmen erkannt\u{201C}: Hörprobe abspielen ▶︎, Namen im Dropdown wählen (die KI schlägt Namen vor, die im Gespräch fielen), „Zuordnung übernehmen\u{201C} — fertig. Tipp: Trage die Teilnehmer schon während des Anrufs im Popup ein, dann stehen die Namen im Dropdown bereit.")
                }

                Group {
                    Text("FREIGABEN (EINMALIG)").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                    HelpTopic(icon: "lock.shield", title: "Mikrofon + Systemaudio",
                              body_: "Beide Freigaben hängen an „calltap\u{201C} (dem Aufnahme-Helfer). macOS fragt beim ersten Start automatisch. Falls die Gegenseite in Aufnahmen stumm ist: Systemeinstellungen → Datenschutz & Sicherheit → **Bildschirm- & Systemaudioaufnahme** → calltap aktivieren. Fürs Mikrofon: gleicher Ort → **Mikrofon**.")
                    HelpTopic(icon: "externaldrive", title: "Externe Festplatte",
                              body_: "Beim ersten Kopieren auf eine externe Platte fragt macOS nach der Freigabe für „Dateien auf Wechseldatenträgern\u{201C} — einmal erlauben, fertig.")
                    HelpTopic(icon: "note.text", title: "Apple Notes / Automation",
                              body_: "Wenn die Ablage in Apple Notes aktiv ist, fragt macOS beim ersten Anruf nach einer Automation-Freigabe (calltap → Notes) — erlauben.")
                }

                Group {
                    Text("EINSTELLUNGEN ERKLÄRT").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                    HelpTopic(icon: "folder", title: "Speicherorte",
                              body_: "**Notizen**: Zielordner der fertigen .md-Notizen — ideal ist dein Obsidian-Vault. **Audio-Archiv**: die m4a-Dateien. **Kopie (extern)**: optionaler Spiegel z. B. auf der externen Platte; wird nach jedem Anruf synchronisiert, verpasste Syncs werden automatisch nachgeholt.")
                    HelpTopic(icon: "cpu", title: "Transkription: Lokal oder Groq",
                              body_: "**Lokal** läuft komplett offline auf deinem Mac (privat, kostenlos). **Groq** ist eine Cloud-API und bei langen Gesprächen deutlich schneller — dafür verlässt das Audio deinen Mac. API-Key gratis auf console.groq.com erstellen; er wird nur lokal gespeichert.")
                    HelpTopic(icon: "brain", title: "KI-Zusammenfassung: deine Wahl",
                              body_: "**Claude Code** (Standard) nutzt dein bestehendes Claude-Abo auf dem Mac. **Eigene KI** spricht jede OpenAI-kompatible API — OpenAI, Groq, OpenRouter oder komplett lokal & kostenlos via Ollama (dann bleibt wirklich alles auf deinem Mac). **Aus** liefert die Notiz nur mit Transkript. Ohne funktionierende KI bricht nichts: Die Notiz kommt trotzdem.")
                    HelpTopic(icon: "list.bullet.rectangle", title: "Notiz-Inhalte",
                              body_: "Wähle, welche Abschnitte die KI schreibt: Kurzfassung, besprochene Punkte, Zusagen & To-dos, und auf Wunsch einen fertigen **Follow-up-Mail-Entwurf** an die Gegenseite.")
                    HelpTopic(icon: "square.and.arrow.up", title: "Ablage-Ziele",
                              body_: "Zusätzlich zur Notiz im Ordner: **Apple Notes** (Ordner „CallNotes\u{201C}), **Nextcloud** (WebDAV; App-Passwort in Nextcloud unter Einstellungen → Sicherheit erzeugen) und **Notion** (Integration auf notion.so/my-integrations anlegen, Token eintragen, Ziel-Seite über ••• → Verbindungen freigeben; Seiten-ID = die 32 Zeichen aus der Seiten-URL).")
                    HelpTopic(icon: "bell.badge", title: "Push (ntfy)",
                              body_: "Kostenlose Push-Nachricht aufs Handy nach jeder Notiz: ntfy.sh-App installieren, ein Thema abonnieren und die URL (https://ntfy.sh/dein-thema) eintragen.")
                }

                Group {
                    Text("WENN ETWAS HAKT").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                    HelpTopic(icon: "questionmark.circle", title: "Aufnahme startet nicht",
                              body_: "Öffne das Protokoll unter `~/CallNotes/log/callwatch.log`. Steht dort ein Hinweis auf eine „nicht gelistete App\u{201C}, ist deine Telefonie-App noch nicht in der Liste bekannter Apps hinterlegt — das lässt sich in der Konfigurationsdatei nachtragen.")
                    HelpTopic(icon: "speaker.slash", title: "Gegenseite ist stumm",
                              body_: "Fast immer die fehlende Systemaudio-Freigabe (siehe oben) — macOS liefert dann Stille statt eines Fehlers. Bei WhatsApp/Discord/Teams hilft manchmal eine Anpassung in der Konfigurationsdatei.")
                    HelpTopic(icon: "arrow.clockwise", title: "Anruf verpasst?",
                              body_: "Verarbeitungen, die nicht geklappt haben, landen mit dem Roh-Audio im Ordner `~/CallNotes/failed/` und lassen sich von dort erneut anstoßen.")
                    HelpTopic(icon: "checkmark.seal", title: "Recht",
                              body_: "Informiere die Gegenseite über die Aufnahme. Die Rechtslage unterscheidet sich je Land — du bist für die rechtmäßige Nutzung verantwortlich.")
                }

                HStack {
                    Button("Ersteinrichtung erneut starten") { SetupWizard.shared.show(store: store) }
                        .controlSize(.small)
                    Spacer()
                    Link("GitHub & Doku", destination: URL(string: "https://github.com/michaelczesun/callnotes")!)
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
        w.title = "CallNotes einrichten"
        w.contentView = view
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
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
    let total = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case 0:
                WizardStepHeader(step: 0, total: total, title: "Willkommen bei CallNotes")
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(accent).frame(width: 64, height: 64)
                        Image(systemName: safeSymbol(["phone.and.waveform.fill", "phone.fill"]))
                            .font(.system(size: 28, weight: .semibold)).foregroundColor(.white)
                    }
                    Text("Du telefonierst — CallNotes macht den Rest.")
                        .font(.callout.weight(.medium))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Erkennt Anrufe automatisch und nimmt beide Seiten getrennt auf", systemImage: "waveform.badge.mic")
                    Label("Transkribiert lokal auf deinem Mac und fasst per KI zusammen", systemImage: "cpu")
                    Label("Legt die fertige Notiz ab, wo du willst — auch externe Platte, Notes, Notion", systemImage: "square.and.arrow.down")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            case 1:
                WizardStepHeader(step: 1, total: total, title: "Freigaben")
                Text("Die Aufnahme übernimmt der Helfer **calltap**. macOS fragt beim ersten Anruf automatisch nach zwei Freigaben — bitte beide erlauben:")
                    .font(.caption).foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Mikrofon — deine Stimme", systemImage: "mic.fill")
                    Label("Systemaudio-Aufnahme — die Stimme der Gegenseite", systemImage: "speaker.wave.2.fill")
                }
                .font(.caption)
                Text("Kam kein Dialog oder ist die Gegenseite später stumm, findest du beides hier:")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Button("Mikrofon-Einstellungen öffnen") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }.controlSize(.small)
                    Button("Systemaudio-Einstellungen öffnen") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }.controlSize(.small)
                }
            case 2:
                WizardStepHeader(step: 2, total: total, title: "Speicherorte")
                Text("Wohin sollen Notizen und Audio? (Später jederzeit änderbar — Kopie ist z. B. deine externe Festplatte.)")
                    .font(.caption).foregroundColor(.secondary)
                PathRow(label: "Notizen", path: $store.notesDir,
                        info: "Zielordner der fertigen Markdown-Notizen. Ideal: dein Obsidian-Vault — dann sind Anrufe sofort verlinkbar.")
                PathRow(label: "Audio-Archiv", path: $store.audioDir,
                        info: "Je Anruf eine m4a-Datei: links dein Mikro, rechts die Gegenseite.")
                PathRow(label: "Kopie (extern)", path: $store.mirrorDir, clearable: true,
                        info: "Optionaler Spiegel-Ordner, z. B. auf der externen Platte. Wird nach jedem Anruf synchronisiert; ist die Platte nicht angeschlossen, wird später automatisch nachgeholt.")
            case 3:
                WizardStepHeader(step: 3, total: total, title: "Transkription & KI")
                Text("Wo soll transkribiert werden?").font(.caption).foregroundColor(.secondary)
                Picker("", selection: $store.transcriber) {
                    Text("Lokal — offline & privat").tag("local")
                    Text("Groq API — schneller").tag("groq")
                }
                .pickerStyle(.segmented).labelsHidden()
                if store.transcriber == "groq" {
                    SecureField("Groq API-Key (console.groq.com)", text: $store.groqApiKey)
                        .textFieldStyle(.roundedBorder).font(.caption)
                }
                Text("Was soll in der Notiz stehen?").font(.caption).foregroundColor(.secondary).padding(.top, 4)
                HStack {
                    wToggle("Kurzfassung", "kurzfassung")
                    wToggle("Besprochen", "besprochen")
                }
                HStack {
                    wToggle("To-dos", "todos")
                    wToggle("Follow-up-Mail", "followup")
                }
            default:
                WizardStepHeader(step: 4, total: total, title: "Fertig!")
                HStack(spacing: 6) {
                    Circle().fill(store.daemonRunning ? Color.green : Color.orange).frame(width: 9, height: 9)
                    Text(store.daemonRunning ? "Der Anruf-Autopilot läuft." : "Autopilot wird beim Abschluss gestartet.")
                        .font(.callout.weight(.medium))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Mach jetzt einen **Testanruf** (länger als 20 Sekunden)", systemImage: "phone.arrow.up.right")
                    Label("Beim ersten Mal die macOS-Freigaben erlauben", systemImage: "lock.open")
                    Label("~1 Minute nach dem Auflegen liegt die Notiz im Notizen-Ordner", systemImage: "doc.text")
                    Label("Alles Weitere: ? in der Menüleiste → Hilfe", systemImage: "questionmark.circle")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
            HStack {
                if step > 0 {
                    Button("Zurück") { step -= 1 }.controlSize(.small)
                }
                Spacer()
                if step < total - 1 {
                    Button("Weiter") { step += 1 }
                        .buttonStyle(.borderedProminent).tint(.indigo)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Einrichtung abschließen") {
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
            .accessibilityLabel("\(label) Lautstärke")
            .accessibilityValue(levels.last.map { Int($0 * 100).description + " Prozent" } ?? "still")
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
                    TextField("Name Teilnehmer \(i + 1)", text: Binding(
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
                    Label("weiterer Teilnehmer", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                InfoTip(title: "Teilnehmer",
                        text: "Wer ist im Gespräch? Die Namen helfen der KI bei der Zusammenfassung und stehen nach Konferenzen im Zuordnungs-Dropdown bereit. Optional — geht auch ohne.")
                Spacer()
                Button(store.participantsSaved ? "Gespeichert ✓" : "Speichern") { store.saveParticipants() }
                    .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            Divider()
            HStack(spacing: 4) {
                Button { store.abortRecording() } label: {
                    Label("Diesen Anruf nicht aufnehmen", systemImage: "mic.slash.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .hoverHighlight()
                InfoTip(title: "Nicht aufnehmen",
                        text: "Verwirft die laufende Aufnahme sofort und unwiderruflich — es wird nichts gespeichert oder verarbeitet. Für diesen Anruf startet die Aufnahme auch nicht neu; ab dem nächsten Anruf ist der Autopilot wieder aktiv.")
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
                    Text("Anruf erkannt").fontWeight(.semibold)
                    Text("via \(store.currentCall?.appName ?? "?") — wer ist dran?")
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
                Text("\(p.speakers.count) Stimmen · \(p.app) · \(p.stamp)")
                    .font(.caption).foregroundColor(.secondary)
                InfoTip(title: "Stimmen zuordnen",
                        text: "Auf der Gegenseite wurden mehrere Stimmen erkannt. ▶︎ spielt eine Hörprobe der jeweiligen Person; wähle dann den Namen im Dropdown (Vorschläge kommen aus dem Gespräch). „Zuordnung übernehmen\u{201C} schreibt die Namen ins Transkript der Notiz.")
                Spacer()
            }
            ForEach(p.speakers) { s in
                let k = store.key(p, s)
                HStack(spacing: 8) {
                    Button { store.playClip(s.clip) } label: {
                        Image(systemName: "play.circle.fill").font(.title2).foregroundColor(.indigo)
                    }
                    .buttonStyle(.plain)
                    .help("Hörprobe \(s.label) (\(Int(s.totalSec))s Redezeit)")
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
                    TextField("Name eingeben", text: Binding(
                        get: { store.customNames[k] ?? "" },
                        set: { store.customNames[k] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 36)
                }
            }
            HStack {
                Button("Notiz ansehen") { NSWorkspace.shared.open(URL(fileURLWithPath: p.note)) }
                    .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                    .padding(.vertical, 3).padding(.horizontal, 4)
                    .hoverHighlight()
                Spacer()
                Button("Zuordnung übernehmen") {
                    justApplied = true
                    store.apply(p)
                }
                    .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.small)
            }
            if justApplied {
                Text("Wird übernommen …").font(.caption2).foregroundColor(.secondary)
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
            Text(path.isEmpty ? "— aus —" : tilde(path))
                .font(.caption)
                .lineLimit(1).truncationMode(.middle)
                .foregroundColor(path.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if clearable && !path.isEmpty {
                Button("aus") { path = "" }.font(.caption).buttonStyle(.plain).foregroundColor(.secondary)
            }
            Button("wählen…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = "Auswählen"
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
            Text("SPEICHERORTE").font(.caption2.weight(.bold)).foregroundColor(.secondary)
            PathRow(label: "Notizen", path: $store.notesDir,
                    info: "Zielordner der fertigen Markdown-Notizen. Ideal: dein Obsidian-Vault — dann sind Anrufe sofort verlinkbar.")
            PathRow(label: "Audio-Archiv", path: $store.audioDir,
                    info: "Je Anruf eine m4a-Datei: links dein Mikro, rechts die Gegenseite.")
            PathRow(label: "Kopie (extern)", path: $store.mirrorDir, clearable: true,
                    info: "Optionaler Spiegel-Ordner, z. B. externe Festplatte. Wird nach jedem Anruf synchronisiert; ist die Platte nicht dran, wird automatisch nachgeholt. Beim ersten Mal fragt macOS nach der Wechseldatenträger-Freigabe.")

            HStack(spacing: 3) {
                Text("TRANSKRIPTION").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                InfoTip(title: "Transkription",
                        text: "Lokal = whisper.cpp direkt auf dem Mac: offline, privat, kostenlos. Groq = Cloud-API, bei langen Gesprächen deutlich schneller — dafür verlässt das Audio deinen Mac.")
            }
            .padding(.top, 4)
            Picker("", selection: $store.transcriber) {
                Text("Lokal (Whisper, offline)").tag("local")
                Text("Groq API (schneller)").tag("groq")
            }
            .pickerStyle(.segmented).labelsHidden()
            if store.transcriber == "groq" {
                HStack(spacing: 4) {
                    SecureField("Groq API-Key (gsk_…)", text: $store.groqApiKey)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    InfoTip(title: "Groq API-Key",
                            text: "Gratis auf console.groq.com erstellen. Der Key wird nur lokal gespeichert (~/.config/callnotes) und nie hochgeladen.")
                }
            }

            HStack(spacing: 3) {
                Text("KI-ZUSAMMENFASSUNG").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                InfoTip(title: "KI-Zusammenfassung",
                        text: "Wer schreibt Kurzfassung & To-dos? Claude Code nutzt dein bestehendes Claude-Abo (Standard). „Eigene KI\u{201C} spricht jede OpenAI-kompatible API — OpenAI, Groq, OpenRouter oder komplett lokal via Ollama. „Aus\u{201C} = Notiz nur mit Transkript.")
            }
            .padding(.top, 4)
            Picker("", selection: $store.summarizer) {
                Text("Claude Code").tag("claude")
                Text("Eigene KI (OpenAI-API)").tag("openai")
                Text("Aus").tag("off")
            }
            .pickerStyle(.segmented).labelsHidden()
            if store.summarizer == "openai" {
                HStack(spacing: 4) {
                    TextField("API-URL, z. B. https://api.openai.com/v1", text: $store.sumUrl)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    InfoTip(title: "API-URL",
                            text: "Basis-URL der OpenAI-kompatiblen API:\nOpenAI: https://api.openai.com/v1\nGroq: https://api.groq.com/openai/v1\nOpenRouter: https://openrouter.ai/api/v1\nOllama (lokal, kostenlos): http://localhost:11434/v1")
                }
                HStack {
                    TextField("Modell, z. B. gpt-4o-mini", text: $store.sumModel)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    SecureField("API-Key (bei Ollama leer)", text: $store.sumKey)
                        .textFieldStyle(.roundedBorder).font(.caption)
                }
            }

            HStack(spacing: 3) {
                Text("NOTIZ-INHALTE").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                InfoTip(title: "Notiz-Inhalte",
                        text: "Welche Abschnitte die KI in die Notiz schreibt. Follow-up-Mail = fertiger Entwurf an die Gegenseite (Dank, Vereinbartes, nächste Schritte). Das Transkript ist immer enthalten.")
            }
            .padding(.top, 4)
            HStack {
                sectionToggle("Kurzfassung", "kurzfassung")
                sectionToggle("Besprochen", "besprochen")
            }
            HStack {
                sectionToggle("To-dos", "todos")
                sectionToggle("Follow-up-Mail", "followup")
            }

            Text("ABLAGE ZUSÄTZLICH IN").font(.caption2.weight(.bold)).foregroundColor(.secondary).padding(.top, 4)
            HStack(spacing: 4) {
                Toggle("Apple Notes (Ordner „CallNotes\u{201C})", isOn: $store.destNotes).font(.caption)
                InfoTip(title: "Apple Notes",
                        text: "Legt jede Notiz zusätzlich in Apple Notes ab (Ordner „CallNotes\u{201C}). Beim ersten Anruf fragt macOS nach einer Automation-Freigabe — erlauben.")
                Spacer()
            }
            HStack(spacing: 4) {
                Toggle("Nextcloud", isOn: $store.destNextcloud.animation(.easeInOut(duration: 0.18))).font(.caption)
                InfoTip(title: "Nextcloud",
                        text: "Lädt die Notiz per WebDAV in deine Cloud (Ordner „CallNotes\u{201C}). App-Passwort in Nextcloud unter Einstellungen → Sicherheit erzeugen — nicht dein Login-Passwort verwenden.")
                Spacer()
            }
            if store.destNextcloud {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Nextcloud-URL (https://…)", text: $store.ncUrl).textFieldStyle(.roundedBorder).font(.caption)
                    HStack {
                        TextField("Benutzer", text: $store.ncUser).textFieldStyle(.roundedBorder).font(.caption)
                        SecureField("App-Passwort", text: $store.ncPass).textFieldStyle(.roundedBorder).font(.caption)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 4) {
                Toggle("Notion", isOn: $store.destNotion.animation(.easeInOut(duration: 0.18))).font(.caption)
                InfoTip(title: "Notion",
                        text: "Erstellt je Anruf eine Unterseite. Integration auf notion.so/my-integrations anlegen, Token hier eintragen und die Ziel-Seite über ••• → Verbindungen für die Integration freigeben. Seiten-ID = die 32 Zeichen aus der Seiten-URL.")
                Spacer()
            }
            if store.destNotion {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Notion Integration-Token (ntn_/secret_…)", text: $store.notionToken).textFieldStyle(.roundedBorder).font(.caption)
                    TextField("Seiten-ID oder Seiten-URL-ID", text: $store.notionParent).textFieldStyle(.roundedBorder).font(.caption)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 3) {
                Text("PUSH").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                InfoTip(title: "ntfy-Push",
                        text: "Kostenlose Push-Nachricht aufs Handy nach jeder fertigen Notiz: ntfy.sh-App installieren, ein Thema abonnieren und hier die URL eintragen (https://ntfy.sh/dein-thema).")
            }
            .padding(.top, 4)
            TextField("ntfy.sh-URL (optional)", text: $store.ntfyUrl).textFieldStyle(.roundedBorder).font(.caption)

            HStack {
                Button("Jetzt syncen") { store.syncNow() }
                    .controlSize(.small).disabled(store.mirrorDir.isEmpty)
                Spacer()
                Button("Speichern & Neustart") { store.saveAndRestart() }
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
    @State private var showSettings = false

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
                    Text(store.currentCall != nil ? "Aufnahme läuft" : (store.daemonRunning ? "Anruf-Autopilot bereit" : "Anruf-Autopilot AUS"))
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
                .help("Hilfe & Erklärungen")
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
                    WaveRow(label: "Du", color: .indigo, levels: store.micLevels)
                    WaveRow(label: "Gegenseite", color: .pink, levels: store.sysLevels)
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

            // Sprecher-Zuordnung
            if !store.pendings.isEmpty {
                ForEach(store.pendings) { p in PendingView(p: p) }
            }

            // Fehlgeschlagene Verarbeitungen: sichtbar machen statt still liegen lassen
            if store.failedCount > 0 {
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text("\(store.failedCount) Aufnahme\(store.failedCount == 1 ? "" : "n") nicht verarbeitet")
                            .font(.callout)
                        InfoTip(title: "Nicht verarbeitet",
                                text: "Diese Anrufe wurden aufgenommen, aber die Verarbeitung schlug fehl (z. B. Whisper-Modell fehlte oder der Mac ging schlafen). Das Roh-Audio ist sicher — „Erneut versuchen\u{201C} startet die Verarbeitung nochmal.")
                        Spacer()
                        Button("Erneut versuchen") { store.retryFailed() }
                            .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
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
                        Text("Noch keine Anrufe aufgezeichnet")
                            .font(.caption).foregroundColor(.secondary)
                        Text("Sobald du telefonierst, erscheint hier die Live-Aufnahme.")
                            .font(.caption2).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // Letzte Anrufe
            if !store.lastNotes.isEmpty {
                Card {
                    Text("LETZTE ANRUFE").font(.caption2.weight(.bold)).foregroundColor(.secondary)
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
                Label("Einstellungen", systemImage: "gearshape.fill")
                    .font(.callout.weight(.medium))
            }

            HStack {
                if !store.status.isEmpty {
                    Text(store.status).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                    .padding(.vertical, 3).padding(.horizontal, 4)
                    .hoverHighlight()
            }
        }
        .padding(14)
        .frame(width: 400)
        }
        .frame(maxHeight: 620)
    }
}

// MARK: - App

@main
struct CallNotesApp: App {
    @StateObject private var store = Store()

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
