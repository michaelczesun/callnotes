// calltap v1.4.0 — Telefonat-Recorder fuer macOS 14.2+ (Core-Audio Process Tap)
//
// Nimmt bei Anrufen ZWEI getrennte Spuren auf:
//   mic.caf    = Mikrofon (du)
//   system.caf = Audio-Ausgabe der Call-App (Gespraechspartner) — via Process Tap,
//                kein BlackHole/Loopback noetig.
//
// Modi:
//   calltap procs [--watch]            Audio-Prozesse anzeigen (wer nutzt gerade das Mikro?)
//   calltap setup                      TCC-Freigaben (Mikrofon + Systemaudio) einmalig ausloesen
//   calltap record --out DIR [--seconds N] [--bundle ID]   manuelle Aufnahme (Ctrl-C stoppt)
//   calltap watch [--config FILE]      Daemon: erkennt Telefonate (Allowlist), auto Start/Stop,
//                                      ruft danach das Post-Skript (Transkript + Notiz)
//                                      Default-Config: ~/.config/callnotes/config.json
import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

// MARK: - Fehler + Logging

struct CalltapError: Error, CustomStringConvertible {
    let msg: String
    init(_ m: String) { msg = m }
    var description: String { msg }
}

let logStamp: () -> String = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return { f.string(from: Date()) }
}()

func log(_ s: String) {
    print("[\(logStamp())] \(s)")
    fflush(stdout)
}

// MARK: - CoreAudio Helpers

func caAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func processObjects() -> [AudioObjectID] {
    var addr = caAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list) == noErr else { return [] }
    return list.filter { $0 != kAudioObjectUnknown }
}

func procPID(_ obj: AudioObjectID) -> pid_t {
    var addr = caAddress(kAudioProcessPropertyPID)
    var pid: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    _ = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid)
    return pid
}

func procBundleID(_ obj: AudioObjectID) -> String {
    var addr = caAddress(kAudioProcessPropertyBundleID)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>? = nil
    let err = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
    }
    guard err == noErr, let v = value?.takeRetainedValue() else { return "" }
    return v as String
}

func procIsRunningInput(_ obj: AudioObjectID) -> Bool {
    var addr = caAddress(kAudioProcessPropertyIsRunningInput)
    var val: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &val) == noErr else { return false }
    return val != 0
}

func processName(_ pid: pid_t) -> String {
    guard pid > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: 1024)
    let n = proc_name(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : ""
}

func defaultOutputDeviceUID() throws -> String {
    var addr = caAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var devID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
          devID != kAudioObjectUnknown else {
        throw CalltapError("Default-Output-Device nicht lesbar")
    }
    var uidAddr = caAddress(kAudioDevicePropertyDeviceUID)
    var uidVal: Unmanaged<CFString>? = nil
    var usize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let err = withUnsafeMutablePointer(to: &uidVal) { AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &usize, $0) }
    guard err == noErr, let u = uidVal?.takeRetainedValue() else { throw CalltapError("Device-UID nicht lesbar") }
    return u as String
}

// MARK: - Systemaudio-Recorder (Process Tap -> Aggregate Device -> CAF)

final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "at.dasgeht.calltap.sys")
    private var _frames: Int64 = 0
    private var _peak: Float = 0
    private var _bufPeaks: [Int: Float] = [:]
    var framesWritten: Int64 { queue.sync { _frames } }
    var peak: Float { queue.sync { _peak } }
    var bufPeaks: [Int: Float] { queue.sync { _bufPeaks } }
    var debug = false
    private var _tickPeak: Float = 0
    // Pegel seit letztem Abruf (fuer Live-Anzeige), setzt sich selbst zurueck
    var levelAndReset: Float {
        queue.sync { let p = _tickPeak; _tickPeak = 0; return p }
    }

    // procs leer = globaler Tap (alles), sonst nur Mixdown dieser Prozesse
    func start(processes procs: [AudioObjectID], outURL: URL) throws {
        let desc: CATapDescription
        if procs.isEmpty {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: procs)
        }
        desc.uuid = UUID()
        desc.name = "calltap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tid = AudioObjectID(kAudioObjectUnknown)
        let terr = AudioHardwareCreateProcessTap(desc, &tid)
        guard terr == noErr, tid != kAudioObjectUnknown else {
            throw CalltapError("Systemaudio-Tap verweigert (err \(terr)). Freigabe noetig: Systemeinstellungen > Datenschutz & Sicherheit > Bildschirm- & Systemaudioaufnahme > calltap.")
        }
        tapID = tid

        var fmtAddr = caAddress(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fsize, &asbd) == noErr,
              let fmt = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw CalltapError("Tap-Format nicht lesbar")
        }
        format = fmt
        do {
            file = try AVAudioFile(forWriting: outURL, settings: fmt.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: fmt.isInterleaved)
        } catch {
            stop() // sonst leakt der bereits erstellte Tap in coreaudiod (z.B. Platte voll)
            throw error
        }

        // Tap-UID lesen (Fallback: UUID der Description)
        var tapUID = desc.uuid.uuidString
        var uidAddr = caAddress(kAudioTapPropertyUID)
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidVal: Unmanaged<CFString>? = nil
        let uidErr = withUnsafeMutablePointer(to: &uidVal) {
            AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, $0)
        }
        if uidErr == noErr, let u = uidVal?.takeRetainedValue() { tapUID = u as String }
        if debug {
            log("DEBUG tap=\(tapID) uidErr=\(uidErr) tapUID=\(tapUID) descUUID=\(desc.uuid.uuidString)")
            log("DEBUG format: \(asbd.mSampleRate)Hz ch=\(asbd.mChannelsPerFrame) flags=\(asbd.mFormatFlags) interleaved=\(fmt.isInterleaved)")
        }

        // Das Default-Output-Geraet liefert die Clock des Aggregats — ohne echtes
        // Sub-Device bleibt der Tap-Stream stumm.
        let outUID = try defaultOutputDeviceUID()
        if debug { log("DEBUG output device UID=\(outUID)") }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "calltap-agg",
            kAudioAggregateDeviceUIDKey as String: "at.dasgeht.calltap.agg." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: outUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapUID,
                 kAudioSubTapDriftCompensationKey as String: true]
            ]
        ]
        var aid = AudioObjectID(kAudioObjectUnknown)
        let aerr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aid)
        guard aerr == noErr, aid != kAudioObjectUnknown else {
            stop()
            throw CalltapError("Aggregate-Device fehlgeschlagen (err \(aerr))")
        }
        aggID = aid

        var pidOut: AudioDeviceIOProcID?
        let perr = AudioDeviceCreateIOProcIDWithBlock(&pidOut, aggID, queue) { [weak self] _, inInputData, _, _, _ in
            guard let self, let fmt = self.format, let f = self.file else { return }
            // Das Aggregate kann neben dem Tap auch Input-Streams des Sub-Devices
            // fuehren (z.B. Interface-Eingaenge) — den Tap-Buffer gezielt waehlen:
            // Taps haengen hinter den Device-Streams, also letzter Buffer mit passender Kanalzahl.
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            var chosen: AudioBuffer? = nil
            if abl.count == 1 {
                chosen = abl[0]
            } else {
                for b in abl where b.mNumberChannels == fmt.channelCount { chosen = b }
                if chosen == nil, abl.count > 0 { chosen = abl[abl.count - 1] }
            }
            guard let cb = chosen, cb.mData != nil else { return }
            if self.debug && self._frames == 0 { log("DEBUG ABL buffers=\(abl.count) gewaehlt: ch=\(cb.mNumberChannels) bytes=\(cb.mDataByteSize)") }
            if self.debug {
                for (bi, b) in abl.enumerated() {
                    guard let data = b.mData else { continue }
                    let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                    let fp = data.assumingMemoryBound(to: Float.self)
                    var mx: Float = 0
                    for i in stride(from: 0, to: n, by: 8) { let v = abs(fp[i]); if v > mx { mx = v } }
                    if mx > self._bufPeaks[bi, default: 0] { self._bufPeaks[bi] = mx }
                }
            }
            var oneABL = AudioBufferList(mNumberBuffers: 1, mBuffers: cb)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: &oneABL, deallocator: nil) else { return }
            if let ch = buf.floatChannelData {
                for c in 0..<Int(buf.format.channelCount) {
                    for i in stride(from: 0, to: Int(buf.frameLength), by: 16) {
                        let v = abs(ch[c][i])
                        if v > self._peak { self._peak = v }
                        if v > self._tickPeak { self._tickPeak = v }
                    }
                }
            }
            do { try f.write(from: buf); self._frames += Int64(buf.frameLength) } catch {}
        }
        guard perr == noErr, let p = pidOut else {
            stop()
            throw CalltapError("IOProc fehlgeschlagen (err \(perr))")
        }
        ioProcID = p
        let serr = AudioDeviceStart(aggID, p)
        guard serr == noErr else {
            stop()
            throw CalltapError("AudioDeviceStart fehlgeschlagen (err \(serr))")
        }
    }

    func stop() {
        if let p = ioProcID, aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, p)
            usleep(150_000) // HAL ausrollen lassen — Destroy direkt nach Stop kann in coreaudiod deadlocken
            AudioDeviceDestroyIOProcID(aggID, p)
        }
        ioProcID = nil
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        queue.sync { file = nil } // flusht + schliesst Datei
    }
}

// MARK: - Mikrofon-Recorder (AVAudioEngine -> CAF)

final class MicRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var _frames: Int64 = 0
    private var _tickPeak: Float = 0
    var framesWritten: Int64 { lock.lock(); defer { lock.unlock() }; return _frames }
    var levelAndReset: Float {
        lock.lock(); defer { lock.unlock() }
        let p = _tickPeak; _tickPeak = 0; return p
    }

    static func ensurePermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            var ok = false
            let sem = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in ok = granted; sem.signal() }
            sem.wait()
            return ok
        default: return false
        }
    }

    func start(outURL: URL) throws {
        guard MicRecorder.ensurePermission() else {
            throw CalltapError("Keine Mikrofon-Freigabe. Systemeinstellungen > Datenschutz & Sicherheit > Mikrofon > calltap erlauben.")
        }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw CalltapError("Kein Eingabegeraet gefunden") }
        let f = try AVAudioFile(forWriting: outURL, settings: fmt.settings,
                                commonFormat: .pcmFormatFloat32, interleaved: fmt.isInterleaved)
        lock.lock(); file = f; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            self.lock.lock()
            if let f = self.file {
                do { try f.write(from: buf); self._frames += Int64(buf.frameLength) } catch {}
                if let ch = buf.floatChannelData {
                    for i in stride(from: 0, to: Int(buf.frameLength), by: 16) {
                        let v = abs(ch[0][i])
                        if v > self._tickPeak { self._tickPeak = v }
                    }
                }
            }
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); file = nil; lock.unlock()
    }
}

// MARK: - Aufnahme-Session (beide Spuren + meta.json)

final class RecordingSession {
    let dir: URL
    let appBundle: String
    let appName: String
    let started = Date()
    private let sys = SystemAudioRecorder()
    private let mic = MicRecorder()
    var debug = false {
        didSet { sys.debug = debug }
    }

    init(dir: URL, appBundle: String, appName: String) {
        self.dir = dir
        self.appBundle = appBundle
        self.appName = appName
    }

    private var levelsTimer: DispatchSourceTimer?

    func start(tapProcesses: [AudioObjectID]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sys.start(processes: tapProcesses, outURL: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(outURL: dir.appendingPathComponent("mic.caf"))
        } catch {
            sys.stop()
            throw error
        }
        startLevels()
    }

    // Live-Pegel beider Spuren fuer die Menueleisten-Anzeige (levels.json im rec-dir)
    private func startLevels() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.4, repeating: 0.35)
        let url = dir.appendingPathComponent("levels.json")
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Sprache peakt typ. 0.1-0.4 -> anheben, auf 0..1 begrenzen
            let m = min(Double(self.mic.levelAndReset) * 3.2, 1.0)
            let s = min(Double(self.sys.levelAndReset) * 3.2, 1.0)
            let obj: [String: Any] = ["mic": m, "sys": s, "t": Date().timeIntervalSince1970]
            if let d = try? JSONSerialization.data(withJSONObject: obj) {
                try? d.write(to: url)
            }
        }
        t.resume()
        levelsTimer = t
    }

    @discardableResult
    func stopAndFinalize() -> TimeInterval {
        if debug { log("DEBUG sysPeak=\(sys.peak) bufPeaks=\(sys.bufPeaks.sorted(by: { $0.key < $1.key })) sysFrames=\(sys.framesWritten) micFrames=\(mic.framesWritten)") }
        levelsTimer?.cancel()
        levelsTimer = nil
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("levels.json"))
        sys.stop()
        mic.stop()
        let dur = Date().timeIntervalSince(started)
        let iso = ISO8601DateFormatter()
        let meta: [String: Any] = [
            "app": appBundle,
            "appName": appName,
            "start": iso.string(from: started),
            "end": iso.string(from: Date()),
            "durationSec": Int(dur),
            "sysFrames": sys.framesWritten,
            "micFrames": mic.framesWritten
        ]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("meta.json"))
        }
        return dur
    }
}

// MARK: - Watch-Konfiguration

struct WatchConfig {
    var apps: [String] = []
    var minSeconds = 20
    var stopGraceSeconds = 6
    var maxHours = 4.0
    var outDir = "~/CallNotes"
    var postScript = ""
    // "app" = Systemaudio nur der Call-App-Familie (Haupt-App + Helper-Prozesse,
    //         wichtig bei Electron-Apps wie WhatsApp/Discord/Teams, wo ein Helper den Ton spielt)
    // "global" = gesamtes Systemaudio (faengt alles, auch Musik im Hintergrund)
    var tapScope = "app"

    static func load(_ path: String) throws -> WatchConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalltapError("Config ist kein JSON-Objekt: \(path)")
        }
        var c = WatchConfig()
        if let v = obj["apps"] as? [String] { c.apps = v }
        if let v = obj["minSeconds"] as? Int { c.minSeconds = v }
        if let v = obj["stopGraceSeconds"] as? Int { c.stopGraceSeconds = v }
        if let v = obj["maxHours"] as? Double { c.maxHours = v }
        if let v = obj["maxHours"] as? Int { c.maxHours = Double(v) }
        if let v = obj["outDir"] as? String { c.outDir = v }
        if let v = obj["postScript"] as? String { c.postScript = v }
        if let v = obj["tapScope"] as? String { c.tapScope = v }
        return c
    }

    func matches(_ bundle: String) -> Bool {
        for pattern in apps {
            if pattern == "*" { return true }
            if pattern.hasSuffix("*"), bundle.hasPrefix(String(pattern.dropLast())) { return true }
            if bundle == pattern { return true }
        }
        return false
    }
}

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

func shortName(_ bundle: String, pid: pid_t) -> String {
    if !bundle.isEmpty, let last = bundle.split(separator: ".").last {
        return String(last).lowercased()
    }
    let n = processName(pid)
    return n.isEmpty ? "app" : n.lowercased()
}

func dirStamp(_ date: Date) -> String {
    // sekundengenau — zwei Anrufe in derselben Minute duerfen nicht kollidieren
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    return f.string(from: date)
}

// MARK: - Kommandos

func cmdProcs(watchMode: Bool) {
    func dump() {
        let procs = processObjects()
        var lines: [String] = []
        for p in procs {
            let running = procIsRunningInput(p)
            if watchMode && !running { continue }
            let pid = procPID(p)
            let bundle = procBundleID(p)
            let name = processName(pid)
            let b = (bundle.isEmpty ? "(kein bundle)" : bundle).padding(toLength: 44, withPad: " ", startingAt: 0)
            lines.append("\(running ? "🎙️ MIC" : "      ") pid=\(String(pid).padding(toLength: 7, withPad: " ", startingAt: 0)) \(b) \(name)")
        }
        if watchMode {
            print("\u{1B}[2J\u{1B}[H— Prozesse mit aktivem Mikrofon (Ctrl-C beendet) —")
        }
        print(lines.isEmpty ? (watchMode ? "(keins aktiv)" : "(keine Audio-Prozesse)") : lines.joined(separator: "\n"))
    }
    if watchMode {
        while true { dump(); Thread.sleep(forTimeInterval: 1.5) }
    } else {
        dump()
    }
}

func cmdSetup() {
    print("1/2 Mikrofon-Freigabe anfordern …")
    let micOK = MicRecorder.ensurePermission()
    print(micOK ? "   ✅ Mikrofon erlaubt" : "   ❌ Mikrofon NICHT erlaubt -> Systemeinstellungen > Datenschutz & Sicherheit > Mikrofon > calltap")
    print("2/2 Systemaudio-Freigabe anfordern (kurzer Test-Tap) …")
    let rec = SystemAudioRecorder()
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("calltap-setup-\(getpid()).caf")
    do {
        try rec.start(processes: [], outURL: tmp)
        Thread.sleep(forTimeInterval: 0.5)
        rec.stop()
        try? FileManager.default.removeItem(at: tmp)
        print("   ✅ Systemaudio erlaubt")
    } catch {
        print("   ❌ Systemaudio NICHT erlaubt: \(error)")
        print("      -> Systemeinstellungen > Datenschutz & Sicherheit > Bildschirm- & Systemaudioaufnahme > calltap aktivieren, dann 'calltap setup' erneut.")
    }
    exit(micOK ? 0 : 1)
}

func cmdRecord(out: String, seconds: Int?, bundle: String?) {
    let dir = URL(fileURLWithPath: expand(out))
    var tapProcs: [AudioObjectID] = []
    var appBundle = "manual"
    var appName = "manuell"
    if let b = bundle {
        let all = processObjects()
        guard let obj = all.first(where: { procBundleID($0) == b }) else {
            log("FEHLER: Kein Audio-Prozess mit Bundle-ID \(b) gefunden (calltap procs zeigt alle).")
            exit(1)
        }
        tapProcs = [obj]
        appBundle = b
        appName = shortName(b, pid: procPID(obj))
    }
    let session = RecordingSession(dir: dir, appBundle: appBundle, appName: appName)
    session.debug = args.contains("--debug")
    do {
        try session.start(tapProcesses: tapProcs)
    } catch {
        log("FEHLER: \(error)")
        exit(1)
    }
    log("Aufnahme laeuft -> \(dir.path) (system.caf + mic.caf). Stoppen: Ctrl-C\(seconds.map { " oder automatisch nach \($0)s" } ?? "")")

    let q = DispatchQueue(label: "at.dasgeht.calltap.ctl")
    let finish: () -> Void = {
        let dur = session.stopAndFinalize()
        log("Aufnahme beendet (\(Int(dur))s).")
        exit(0)
    }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: q)
        src.setEventHandler(handler: finish)
        src.resume()
        signalSources.append(src)
    }
    if let s = seconds {
        q.asyncAfter(deadline: .now() + .seconds(s), execute: finish)
    }
    dispatchMain()
}

var signalSources: [DispatchSourceSignal] = []

func cmdWatch(configPath: String) {
    let cfg: WatchConfig
    do { cfg = try WatchConfig.load(configPath) } catch {
        log("FEHLER Config: \(error)")
        exit(1)
    }
    let base = URL(fileURLWithPath: expand(cfg.outDir))
    let recBase = base.appendingPathComponent("rec")
    let stateDir = base.appendingPathComponent("state")
    let currentCallFile = stateDir.appendingPathComponent("current-call.json")
    try? FileManager.default.createDirectory(at: recBase, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: stateDir.appendingPathComponent("pending"), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: currentCallFile) // Reste eines Absturzes
    // Verwaiste Aufnahmen eines Absturzes (rec-dir ohne meta.json) nach failed/
    // verschieben — dort macht die Menueleisten-App sie sichtbar (Erneut versuchen).
    let failedDir = base.appendingPathComponent("failed")
    try? FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)
    for entry in (try? FileManager.default.contentsOfDirectory(at: recBase, includingPropertiesForKeys: nil)) ?? [] {
        guard entry.hasDirectoryPath,
              !FileManager.default.fileExists(atPath: entry.appendingPathComponent("meta.json").path) else { continue }
        try? FileManager.default.removeItem(at: entry.appendingPathComponent("levels.json"))
        try? FileManager.default.moveItem(at: entry, to: failedDir.appendingPathComponent(entry.lastPathComponent))
        log("Verwaiste Aufnahme nach Absturz -> failed/: \(entry.lastPathComponent)")
    }
    let post = expand(cfg.postScript)
    log("callwatch gestartet. Apps: \(cfg.apps.joined(separator: ", ")) | min \(cfg.minSeconds)s | Stopp nach \(cfg.stopGraceSeconds)s Stille | Ausgabe \(base.path)")

    // Self-Test beim Start: loest den TCC-Prompt JETZT aus (nicht mitten im ersten
    // Anruf). Bewusst NUR Tap-Create/Destroy — ein voller Aggregate+IOProc-Zyklus
    // im Schnelldurchlauf kann in coreaudiod deadlocken.
    do {
        let d = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        d.uuid = UUID()
        d.name = "calltap-selftest"
        d.isPrivate = true
        var tid = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateProcessTap(d, &tid)
        if err == noErr, tid != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tid)
            log("Self-Test: Systemaudio-Tap ok")
        } else {
            log("WARNUNG Self-Test: Tap verweigert (err \(err)) — Systemeinstellungen > Datenschutz & Sicherheit > Bildschirm- & Systemaudioaufnahme > calltap aktivieren")
        }
    }
    if !MicRecorder.ensurePermission() {
        log("WARNUNG: keine Mikrofon-Freigabe — Systemeinstellungen > Datenschutz & Sicherheit > Mikrofon > calltap")
    }

    let q = DispatchQueue(label: "at.dasgeht.calltap.watch")
    var session: RecordingSession? = nil
    var silentSince: Date? = nil
    var lastStartError: Date? = nil
    var loggedUnknown = Set<String>()
    // Nach "Nicht aufnehmen": diese App bis zum Ende des Anrufs nicht erneut aufnehmen
    var suppressBundle: String? = nil
    var suppressIdleSince: Date? = nil

    func spawnPost(_ dir: URL) {
        guard !post.isEmpty else { log("Kein postScript konfiguriert — Aufnahme bleibt in \(dir.path)"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let logFile = base.appendingPathComponent("log/process.log").path
        p.arguments = ["-c", "nohup /bin/bash '\(post)' '\(dir.path)' >> '\(logFile)' 2>&1 &"]
        do { try p.run() } catch { log("Post-Skript-Start fehlgeschlagen: \(error)") }
    }

    // Alle Audio-Prozesse derselben App-Familie (Haupt-App + .helper-Prozesse) —
    // bei Electron-Apps spielt oft ein Helper den Call-Ton, nicht der Mikro-Prozess.
    func tapTargets(trigger obj: AudioObjectID, bundle: String) -> [AudioObjectID] {
        if cfg.tapScope == "global" { return [] }
        guard !bundle.isEmpty else { return [obj] }
        var family: [AudioObjectID] = []
        for p in processObjects() {
            let b = procBundleID(p)
            if b == bundle || b.hasPrefix(bundle + ".") { family.append(p) }
        }
        return family.isEmpty ? [obj] : family
    }

    // Live-Status fuer die CallNotes-Menueleisten-App (Popup "wer ist dran?")
    func writeCurrentCall(_ s: RecordingSession) {
        let info: [String: Any] = [
            "dir": s.dir.path,
            "app": s.appBundle,
            "appName": s.appName,
            "start": ISO8601DateFormatter().string(from: s.started)
        ]
        if let d = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
            try? d.write(to: currentCallFile)
        }
    }

    func finish(_ s: RecordingSession, reason: String) {
        let dur = s.stopAndFinalize()
        session = nil
        silentSince = nil
        try? FileManager.default.removeItem(at: currentCallFile)
        if Int(dur) < cfg.minSeconds {
            log("REC ENDE \(s.appBundle) nach \(Int(dur))s (\(reason)) — zu kurz, verworfen")
            try? FileManager.default.removeItem(at: s.dir)
        } else {
            log("REC ENDE \(s.appBundle) nach \(Int(dur))s (\(reason)) -> Verarbeitung startet")
            spawnPost(s.dir)
        }
    }

    // "Nicht aufnehmen" aus dem Popup: sofort stoppen, alles loeschen, nichts verarbeiten —
    // und dieselbe App bis zum Ende dieses Anrufs nicht erneut anfassen.
    func discard(_ s: RecordingSession) {
        _ = s.stopAndFinalize()
        session = nil
        silentSince = nil
        // generischer Fallback-Name "app" wuerde spaeter FREMDE Prozesse mit-unterdruecken
        let key = s.appBundle.isEmpty ? s.appName : s.appBundle
        suppressBundle = key == "app" ? nil : key
        suppressIdleSince = nil
        try? FileManager.default.removeItem(at: currentCallFile)
        try? FileManager.default.removeItem(at: s.dir)
        log("REC VERWORFEN (\(s.appBundle)) auf Nutzerwunsch — dieser Anruf wird nicht aufgenommen")
    }

    let timer = DispatchSource.makeTimerSource(queue: q)
    timer.schedule(deadline: .now() + 1, repeating: 2.0)
    timer.setEventHandler {
        // Abbruch-Wunsch der UI? (Marker-Datei im Aufnahme-Ordner)
        if let s = session, FileManager.default.fileExists(atPath: s.dir.appendingPathComponent("abort").path) {
            discard(s)
        }

        var active: (AudioObjectID, String)? = nil
        for p in processObjects() {
            guard procIsRunningInput(p) else { continue }
            let bundle = procBundleID(p)
            // Nie auf sich selbst triggern — direkt gestartete Binaries haben in
            // CoreAudio KEINE Bundle-ID, deshalb zusaetzlich der Prozessname.
            if bundle == "at.dasgeht.calltap" || processName(procPID(p)) == "calltap" { continue }
            if cfg.matches(bundle) {
                active = (p, bundle)
                break
            } else if session == nil {
                let key = bundle.isEmpty ? "pid-\(procPID(p))" : bundle
                if !loggedUnknown.contains(key) {
                    loggedUnknown.insert(key)
                    log("INFO: Mikro aktiv bei nicht gelisteter App: \(key) (\(processName(procPID(p)))) — falls Telefonate darueber laufen, in callwatch.json bei 'apps' ergaenzen")
                }
            }
        }

        // Unterdrueckung nach "Nicht aufnehmen": solange dieselbe App das Mikro haelt,
        // nicht neu starten; erst wenn der Anruf wirklich vorbei ist, wieder scharf.
        if let sb = suppressBundle {
            let stillActive = active.map { $0.1.isEmpty ? shortName($0.1, pid: procPID($0.0)) == sb : ($0.1 == sb) } ?? false
            if stillActive {
                suppressIdleSince = nil
                return
            }
            if suppressIdleSince == nil { suppressIdleSince = Date() }
            if let si = suppressIdleSince, Date().timeIntervalSince(si) >= Double(cfg.stopGraceSeconds) {
                suppressBundle = nil
                suppressIdleSince = nil
                log("Abbruch-Sperre aufgehoben — naechster Anruf wird wieder aufgenommen")
            }
        }

        if let (obj, bundle) = active {
            silentSince = nil
            if session == nil {
                if let le = lastStartError, Date().timeIntervalSince(le) < 60 { return } // kein Prompt-/Fehler-Sturm
                let name = shortName(bundle, pid: procPID(obj))
                let dir = recBase.appendingPathComponent(dirStamp(Date()) + "_" + name)
                let s = RecordingSession(dir: dir, appBundle: bundle, appName: name)
                do {
                    let targets = tapTargets(trigger: obj, bundle: bundle)
                    try s.start(tapProcesses: targets)
                    session = s
                    writeCurrentCall(s)
                    log("REC START \(bundle.isEmpty ? name : bundle) (tap: \(targets.isEmpty ? "global" : "\(targets.count) prozess(e)")) -> \(dir.path)")
                } catch {
                    lastStartError = Date()
                    log("REC START FEHLER (\(bundle)): \(error)")
                }
            } else if let s = session, Date().timeIntervalSince(s.started) > cfg.maxHours * 3600 {
                finish(s, reason: "Maximaldauer erreicht")
            }
        } else if let s = session {
            if silentSince == nil { silentSince = Date() }
            if let ss = silentSince, Date().timeIntervalSince(ss) >= Double(cfg.stopGraceSeconds) {
                finish(s, reason: "Anruf beendet")
            }
        }
    }
    timer.resume()

    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: q)
        src.setEventHandler {
            if let s = session { finish(s, reason: "callwatch gestoppt") }
            log("callwatch beendet.")
            exit(0)
        }
        src.resume()
        signalSources.append(src)
    }
    dispatchMain()
}

// MARK: - Main

func usage() -> Never {
    print("""
    calltap v1.4.0 — Telefonat-Recorder (2 Spuren: Mikro + Systemaudio der Call-App)

    Nutzung:
      calltap procs [--watch]                     Audio-Prozesse (wer nutzt das Mikro?)
      calltap setup                               TCC-Freigaben einmalig ausloesen
      calltap record --out DIR [--seconds N] [--bundle ID]
      calltap watch [--config FILE]               Default: ~/.config/callnotes/config.json
    """)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())

// Doppelklick im Finder (keine Argumente, kein Terminal): calltap ist der
// unsichtbare Recorder — stattdessen die CallNotes-Oberflaeche oeffnen.
if args.isEmpty && isatty(0) == 0 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-b", "at.dasgeht.callnotes"]
    try? p.run()
    exit(0)
}
guard let cmd = args.first else { usage() }

func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch cmd {
case "procs":
    cmdProcs(watchMode: args.contains("--watch"))
case "setup":
    cmdSetup()
case "record":
    guard let out = flagValue("--out") else { usage() }
    cmdRecord(out: out, seconds: flagValue("--seconds").flatMap { Int($0) }, bundle: flagValue("--bundle"))
case "watch":
    cmdWatch(configPath: flagValue("--config") ?? "~/.config/callnotes/config.json")
default:
    usage()
}
