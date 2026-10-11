// Recording-list settings shared by the menu-bar app and recorder.
import Foundation
import Darwin

struct RecordingAppEntry: Identifiable {
    let pattern: String
    let name: String
    var id: String { pattern }
}

struct RecordingAppList: Equatable {
    var enabled: [String] = []
    var disabled: [String] = []

    // Presence in this catalogue never enables an entry automatically.
    static let catalogue: [RecordingAppEntry] = [
        RecordingAppEntry(pattern: "com.apple.TelephonyUtilities", name: "Continuity / iPhone"),
        RecordingAppEntry(pattern: "com.apple.avconferenced", name: "FaceTime audio service"),
        RecordingAppEntry(pattern: "com.apple.FaceTime", name: "FaceTime"),
        RecordingAppEntry(pattern: "com.apple.Phone", name: "Phone"),
        RecordingAppEntry(pattern: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        RecordingAppEntry(pattern: "us.zoom.xos", name: "Zoom"),
        RecordingAppEntry(pattern: "com.microsoft.teams2", name: "Microsoft Teams"),
        RecordingAppEntry(pattern: "com.microsoft.teams", name: "Microsoft Teams (classic)"),
        RecordingAppEntry(pattern: "org.whispersystems.signal-desktop", name: "Signal"),
        RecordingAppEntry(pattern: "ru.keepcoder.Telegram", name: "Telegram"),
        RecordingAppEntry(pattern: "com.hnc.Discord", name: "Discord"),
        RecordingAppEntry(pattern: "com.apple.WebKit*", name: "WebKit / Safari"),
        RecordingAppEntry(pattern: "com.apple.CoreSpeech*", name: "CoreSpeech")
    ]

    var entries: [RecordingAppEntry] {
        let names = Dictionary(uniqueKeysWithValues: Self.catalogue.map { ($0.pattern, $0.name) })
        return Self.unique(Self.catalogue.map(\.pattern) + enabled + disabled).map { pattern in
            RecordingAppEntry(pattern: pattern, name: names[pattern] ?? pattern)
        }
    }

    static func unique(_ patterns: [String]) -> [String] {
        var seen = Set<String>()
        return patterns.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    init(enabled: [String] = [], disabled: [String] = []) {
        self.enabled = Self.unique(enabled)
        self.disabled = Self.unique(disabled).filter { !self.enabled.contains($0) }
    }

    init(configuration: [String: Any]) throws {
        for key in ["apps", "disabledApps"] {
            if let value = configuration[key], !(value is [String]) {
                throw ConfigurationError.invalidList(key)
            }
        }
        self.init(enabled: configuration["apps"] as? [String] ?? [],
                  disabled: configuration["disabledApps"] as? [String] ?? [])
    }

    static func readConfiguration(from url: URL) throws -> [String: Any] {
        guard let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ConfigurationError.invalidObject
        }
        return configuration
    }

    static func read(from url: URL) throws -> RecordingAppList {
        try RecordingAppList(configuration: readConfiguration(from: url))
    }

    // Read at save time: never overwrite another app's or the user's newer settings.
    static func setEnabled(_ enabled: Bool, pattern: String, at url: URL) throws -> RecordingAppList {
        guard !pattern.isEmpty else { throw ConfigurationError.invalidList("apps") }
        var configuration = try readConfiguration(from: url)
        var list = try RecordingAppList(configuration: configuration)
        list.enabled.removeAll { $0 == pattern }
        list.disabled.removeAll { $0 == pattern }
        if enabled { list.enabled.append(pattern) } else { list.disabled.append(pattern) }
        configuration["apps"] = list.enabled
        configuration["disabledApps"] = list.disabled
        try writeConfiguration(configuration, to: url)
        return list
    }

    static func saveSettings(_ updates: [String: Any], at url: URL) throws -> [String: Any] {
        var configuration = try readConfiguration(from: url)
        for (key, value) in updates { configuration[key] = value }
        try writeConfiguration(configuration, to: url)
        return configuration
    }

    static func writeConfiguration(_ configuration: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".config-\(UUID().uuidString).tmp")
        // Create private BEFORE writing any credentials. Rename within the same directory
        // makes the replacement atomic; no reader can observe a partially written config.
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func matches(_ bundle: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            pattern == bundle || (pattern.hasSuffix("*") && bundle.hasPrefix(String(pattern.dropLast())))
        }
    }

    enum ConfigurationError: LocalizedError {
        case invalidObject
        case invalidList(String)
        var errorDescription: String? {
            switch self {
            case .invalidObject: return "CallNotes configuration must be a JSON object."
            case .invalidList(let key): return "CallNotes '\(key)' must be a list of bundle-ID patterns."
            }
        }
    }
}

struct RecordingAppReload {
    private(set) var enabled: [String]

    // Keep the old list for the entire active recording. At idle, use the latest
    // saved list (including edits made while the menu-bar app was closed).
    mutating func reload(from url: URL, isRecording: Bool) throws -> Bool {
        guard !isRecording else { return false }
        let latest = try RecordingAppList.read(from: url).enabled
        guard latest != enabled else { return false }
        enabled = latest
        return true
    }

    func matches(_ bundle: String) -> Bool {
        RecordingAppList.matches(bundle, patterns: enabled)
    }
}
