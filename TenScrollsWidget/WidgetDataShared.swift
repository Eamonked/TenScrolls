import Foundation

// MARK: - Daily Practice Widget Data

struct WidgetData: Codable {
    var streak: Int
    var activeScrollRoman: String
    var activeScrollTitle: String
    var daysCompletedOnActive: Int
    var dawnComplete: Bool
    var middayComplete: Bool
    var duskComplete: Bool
    var themeId: String
    var lastUpdated: Date
    
    static let sharedDefaults = UserDefaults(suiteName: "group.ekme.TenScrolls")
    
    static func save(_ data: WidgetData) {
        if let encoded = try? JSONEncoder().encode(data) {
            sharedDefaults?.set(encoded, forKey: "widgetData")
        }
    }
    
    static func load() -> WidgetData? {
        if let data = sharedDefaults?.data(forKey: "widgetData"),
           let decoded = try? JSONDecoder().decode(WidgetData.self, from: data) {
            return decoded
        }
        return nil
    }
}

// MARK: - Journal Widget Data

struct JournalWidgetData: Codable {
    var entries: [JournalWidgetEntry]
    var themeId: String
    var lastUpdated: Date
    
    static let sharedDefaults = UserDefaults(suiteName: "group.ekme.TenScrolls")
    
    static func save(_ data: JournalWidgetData) {
        if let encoded = try? JSONEncoder().encode(data) {
            sharedDefaults?.set(encoded, forKey: "journalWidgetData")
        }
    }
    
    static func load() -> JournalWidgetData? {
        if let data = sharedDefaults?.data(forKey: "journalWidgetData"),
           let decoded = try? JSONDecoder().decode(JournalWidgetData.self, from: data) {
            return decoded
        }
        return nil
    }
    
    struct JournalWidgetEntry: Codable, Identifiable {
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
