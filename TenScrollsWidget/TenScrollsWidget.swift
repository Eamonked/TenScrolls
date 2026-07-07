import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        let data = WidgetData.load() ?? .placeholder
        let entry = WidgetEntry(date: Date(), data: data)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let data = WidgetData.load() ?? .placeholder
        let entry = WidgetEntry(date: Date(), data: data)
        // Refresh periodically just in case, but rely mostly on the main app triggering reloads
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct WidgetEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

extension WidgetData {
    static var placeholder: WidgetData {
        WidgetData(
            streak: 12,
            activeScrollRoman: "IV",
            activeScrollTitle: "The Scroll of Action",
            daysCompletedOnActive: 8,
            dawnComplete: true,
            middayComplete: false,
            duskComplete: false,
            themeId: "brass",
            lastUpdated: Date()
        )
    }
}

struct TenScrollsWidget: Widget {
    let kind: String = "TenScrollsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            TenScrollsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Daily Practice")
        .description("Keep your daily reading progress at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
