import Foundation

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
