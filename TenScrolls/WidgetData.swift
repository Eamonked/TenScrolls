import Foundation

// MARK: - Shared storage plumbing

/// Where and how the app and widget extension exchange small blobs of
/// widget-facing data. Both targets keep their own copy of this file (see
/// `WidgetData.swift` here and `WidgetDataShared.swift` in TenScrollsWidget)
/// since they can't share a Swift file across a file-system-synchronized
/// target boundary — keep the two in sync by hand if either changes.
///
/// Storage strategy: prefer writing/reading a JSON file inside the App
/// Group's shared container (`FileManager.containerURL`), since it isn't
/// subject to UserDefaults' size guidance and is simpler to inspect/debug.
/// Fall back to the App Group's suite `UserDefaults` only when the container
/// is unavailable (missing/mismatched entitlement, disk error, etc) — this
/// also keeps existing installs' already-persisted UserDefaults data
/// readable until the next `save` migrates it to the container.
nonisolated enum WidgetStorage {
    /// The App Group identifier, resolved from the `APP_GROUP_IDENTIFIER`
    /// build setting (see the project's shared build settings) which Xcode
    /// substitutes into each target's Info.plist as `AppGroupIdentifier`.
    /// Deliberately not a string literal here — the app and widget targets
    /// read the *same* build setting, so they can't silently drift apart the
    /// way two independently hand-typed literals could.
    static let appGroupIdentifier: String? = {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              !id.isEmpty else {
            return nil
        }
        return id
    }()

    /// The shared container directory for the App Group, if the entitlement
    /// is configured on this target and matches the other target exactly.
    /// `nil` when `appGroupIdentifier` is missing, or the OS can't resolve a
    /// container for it (almost always a missing/mismatched "App Groups"
    /// capability in Signing & Capabilities).
    static let containerURL: URL? = {
        guard let id = appGroupIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }()

    /// Fallback storage: the App Group's suite `UserDefaults`. Also where
    /// installs from before file-based storage existed may still have data.
    /// `(unsafe)` because `UserDefaults` doesn't conform to `Sendable` on
    /// this SDK, even though it's Apple-documented as thread-safe — this is
    /// the standard escape hatch for known-safe-but-unannotated Foundation
    /// types under strict concurrency, not a real safety gap.
    nonisolated(unsafe) static let sharedDefaults: UserDefaults? = appGroupIdentifier.flatMap { UserDefaults(suiteName: $0) }

    /// Logs the App Group's resolution state at startup (see
    /// `TenScrollsApp.init` and `TenScrollsWidgetBundle.init`) so a missing
    /// or mismatched entitlement shows up immediately in the console/CI
    /// instead of surfacing later as a silently-empty widget.
    static func logStartupDiagnostics(caller: String) {
        guard let id = appGroupIdentifier else {
            print("⚠️ TenScrolls[\(caller)]: 'AppGroupIdentifier' is missing/empty in Info.plist. Widget data will fall back to standard (non-shared) UserDefaults and will NOT sync between the app and widget. Check the APP_GROUP_IDENTIFIER build setting.")
            return
        }
        if containerURL == nil {
            print("⚠️ TenScrolls[\(caller)]: App Group container unavailable for '\(id)'. Widget data will fall back to shared UserDefaults. Check that the 'App Groups' capability is enabled on this target (Signing & Capabilities) with entitlement '\(id)', and that it matches exactly on both the TenScrolls and TenScrollsWidgetExtension targets.")
            return
        }
        print("✅ TenScrolls[\(caller)]: App Group '\(id)' resolved (container + shared UserDefaults available).")
    }

    /// Encodes `value` and writes it to the App Group container file at
    /// `filename` when possible, falling back to the App Group's suite
    /// `UserDefaults` under `defaultsKey` only if the container write fails.
    static func save<T: Encodable>(_ value: T, filename: String, defaultsKey: String) {
        guard let encoded = try? JSONEncoder().encode(value) else { return }
        if let containerURL {
            let fileURL = containerURL.appendingPathComponent(filename)
            if (try? encoded.write(to: fileURL, options: .atomic)) != nil {
                return
            }
        }
        sharedDefaults?.set(encoded, forKey: defaultsKey)
    }

    /// Loads a value previously written by `save`, preferring the App Group
    /// container file and falling back to the App Group's suite
    /// `UserDefaults` — either because the container was unavailable at save
    /// time, or the data predates file-based storage.
    static func load<T: Decodable>(_ type: T.Type, filename: String, defaultsKey: String) -> T? {
        if let containerURL {
            let fileURL = containerURL.appendingPathComponent(filename)
            if let data = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(T.self, from: data) {
                return decoded
            }
        }
        if let data = sharedDefaults?.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        return nil
    }
}

// MARK: - Daily Practice Widget Data

nonisolated struct WidgetData: Codable {
    var streak: Int
    var activeScrollRoman: String
    var activeScrollTitle: String
    var daysCompletedOnActive: Int
    var dawnComplete: Bool
    var middayComplete: Bool
    var duskComplete: Bool
    var themeId: String
    var lastUpdated: Date

    private static let filename = "widgetData.json"
    private static let defaultsKey = "widgetData"

    static func save(_ data: WidgetData) {
        WidgetStorage.save(data, filename: filename, defaultsKey: defaultsKey)
    }

    static func load() -> WidgetData? {
        WidgetStorage.load(WidgetData.self, filename: filename, defaultsKey: defaultsKey)
    }
}

// MARK: - Journal Widget Data

nonisolated struct JournalWidgetData: Codable {
    var entries: [JournalWidgetEntry]
    var themeId: String
    var lastUpdated: Date

    private static let filename = "journalWidgetData.json"
    private static let defaultsKey = "journalWidgetData"

    static func save(_ data: JournalWidgetData) {
        WidgetStorage.save(data, filename: filename, defaultsKey: defaultsKey)
    }

    static func load() -> JournalWidgetData? {
        WidgetStorage.load(JournalWidgetData.self, filename: filename, defaultsKey: defaultsKey)
    }

    nonisolated struct JournalWidgetEntry: Codable, Identifiable {
        let id: String
        let text: String
        let date: String
        let scrollRoman: String?
        
        init(id: String, text: String, date: String, scrollRoman: String?) {
            self.id = id
            self.text = text
            self.date = date
            self.scrollRoman = scrollRoman
        }
    }
}
