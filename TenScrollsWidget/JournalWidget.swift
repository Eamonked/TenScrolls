import WidgetKit
import SwiftUI

struct JournalProvider: TimelineProvider {
    func placeholder(in context: Context) -> JournalWidgetEntry {
        JournalWidgetEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (JournalWidgetEntry) -> Void) {
        let data = JournalWidgetData.load() ?? .placeholder
        let entry = JournalWidgetEntry(date: Date(), data: data)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let data = JournalWidgetData.load() ?? .placeholder
        let currentDate = Date()
        
        // Create entries for the next 24 hours, rotating through journal entries every 2 hours
        var entries: [JournalWidgetEntry] = []
        
        if data.entries.isEmpty {
            // If no entries, show placeholder
            let entry = JournalWidgetEntry(date: currentDate, data: data)
            entries.append(entry)
        } else {
            // Rotate through random entries every 2 hours
            for hourOffset in 0..<12 {
                if let entryDate = Calendar.current.date(byAdding: .hour, value: hourOffset * 2, to: currentDate) {
                    let entry = JournalWidgetEntry(date: entryDate, data: data)
                    entries.append(entry)
                }
            }
        }
        
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 2, to: currentDate)!
        let timeline = Timeline(entries: entries, policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct JournalWidgetEntry: TimelineEntry {
    let date: Date
    let data: JournalWidgetData
    
    // Pick a random entry based on the current date/time to ensure it changes
    var selectedEntry: JournalWidgetData.JournalWidgetEntry? {
        guard !data.entries.isEmpty else { return nil }
        
        // Use date as seed for deterministic "randomness" that changes over time
        let hoursSinceReference = Int(date.timeIntervalSinceReferenceDate / 7200) // Changes every 2 hours
        let index = abs(hoursSinceReference) % data.entries.count
        return data.entries[index]
    }
}

extension JournalWidgetData {
    static var placeholder: JournalWidgetData {
        JournalWidgetData(
            entries: [
                JournalWidgetData.JournalWidgetEntry(
                    id: "1",
                    text: "Today I realized that consistency beats intensity. Small daily actions compound into remarkable results over time.",
                    date: "Dec 15",
                    scrollRoman: "IV"
                )
            ],
            themeId: "brass",
            lastUpdated: Date()
        )
    }
}

struct JournalWidget: Widget {
    let kind: String = "JournalWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JournalProvider()) { entry in
            JournalWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Journal Reflection")
        .description("Display a random reflection from your journal.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct JournalWidgetEntryView: View {
    var entry: JournalProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            JournalWidgetSmallView(entry: entry)
        case .systemMedium:
            JournalWidgetMediumView(entry: entry)
        case .systemLarge:
            JournalWidgetLargeView(entry: entry)
        case .accessoryRectangular:
            JournalWidgetAccessoryRectangularView(entry: entry)
        @unknown default:
            JournalWidgetSmallView(entry: entry)
        }
    }
}

// MARK: - Small Widget

struct JournalWidgetSmallView: View {
    let entry: JournalProvider.Entry
    
    var themeBrass: Color { WidgetPalette.themeBrass(for: entry.data.themeId) }
    
    var body: some View {
        ZStack {
            WidgetPalette.background.ignoresSafeArea()
            
            if let journalEntry = entry.selectedEntry {
                VStack(alignment: .leading, spacing: 8) {
                    // Header
                    HStack {
                        Image(systemName: "book.closed")
                            .font(.system(size: 10))
                            .foregroundColor(themeBrass)
                        Text("JOURNAL")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(themeBrass)
                    }
                    
                    // Entry text (truncated)
                    Text(journalEntry.text)
                        .font(.system(size: 12, weight: .regular, design: .serif))
                        .foregroundColor(WidgetPalette.text)
                        .lineLimit(5)
                        .lineSpacing(2)
                    
                    Spacer()
                    
                    // Footer
                    HStack(spacing: 4) {
                        Text(journalEntry.date)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(WidgetPalette.textFaint)
                        if let roman = journalEntry.scrollRoman {
                            Text("·")
                                .foregroundColor(WidgetPalette.textFaint)
                            Text("Scroll \(roman)")
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundColor(WidgetPalette.textFaint)
                        }
                    }
                }
                .padding(14)
            } else {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 24))
                        .foregroundColor(WidgetPalette.textFaint)
                    Text("No journal entries yet")
                        .font(.system(size: 11))
                        .foregroundColor(WidgetPalette.textDim)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }
}

// MARK: - Medium Widget

struct JournalWidgetMediumView: View {
    let entry: JournalProvider.Entry
    
    var themeBrass: Color { WidgetPalette.themeBrass(for: entry.data.themeId) }
    
    var body: some View {
        ZStack {
            WidgetPalette.background.ignoresSafeArea()
            
            if let journalEntry = entry.selectedEntry {
                VStack(alignment: .leading, spacing: 10) {
                    // Header
                    HStack {
                        Image(systemName: "book.closed")
                            .font(.system(size: 11))
                            .foregroundColor(themeBrass)
                        Text("JOURNAL REFLECTION")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(themeBrass)
                        Spacer()
                        // Date and scroll
                        HStack(spacing: 4) {
                            Text(journalEntry.date)
                                .font(.system(size: 9, design: .monospaced))
                            if let roman = journalEntry.scrollRoman {
                                Text("·")
                                Text("Scroll \(roman)")
                                    .font(.system(size: 9, design: .monospaced))
                            }
                        }
                        .foregroundColor(WidgetPalette.textFaint)
                    }
                    
                    // Entry text
                    Text(journalEntry.text)
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .foregroundColor(WidgetPalette.text)
                        .lineLimit(4)
                        .lineSpacing(3)
                    
                    Spacer()
                }
                .padding(16)
            } else {
                // Empty state
                VStack(spacing: 10) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 32))
                        .foregroundColor(WidgetPalette.textFaint)
                    Text("No journal entries yet")
                        .font(.system(size: 13))
                        .foregroundColor(WidgetPalette.textDim)
                    Text("Start journaling to see your reflections here")
                        .font(.system(size: 10))
                        .foregroundColor(WidgetPalette.textFaint)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }
}

// MARK: - Large Widget

struct JournalWidgetLargeView: View {
    let entry: JournalProvider.Entry
    
    var themeBrass: Color { WidgetPalette.themeBrass(for: entry.data.themeId) }
    
    var body: some View {
        ZStack {
            WidgetPalette.background.ignoresSafeArea()
            
            if let journalEntry = entry.selectedEntry {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "book.closed")
                                    .font(.system(size: 12))
                                    .foregroundColor(themeBrass)
                                Text("JOURNAL REFLECTION")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(themeBrass)
                            }
                            HStack(spacing: 4) {
                                Text(journalEntry.date)
                                    .font(.system(size: 10, design: .monospaced))
                                if let roman = journalEntry.scrollRoman {
                                    Text("·")
                                    Text("Scroll \(roman)")
                                        .font(.system(size: 10, design: .monospaced))
                                }
                            }
                            .foregroundColor(WidgetPalette.textFaint)
                        }
                        Spacer()
                    }
                    
                    // Decorative divider
                    HStack {
                        Rectangle()
                            .fill(themeBrass.opacity(0.3))
                            .frame(height: 1)
                        Circle()
                            .fill(themeBrass.opacity(0.4))
                            .frame(width: 4, height: 4)
                        Rectangle()
                            .fill(themeBrass.opacity(0.3))
                            .frame(height: 1)
                    }
                    
                    // Entry text - more lines for large widget
                    Text(journalEntry.text)
                        .font(.system(size: 15, weight: .regular, design: .serif))
                        .foregroundColor(WidgetPalette.text)
                        .lineLimit(12)
                        .lineSpacing(4)
                    
                    Spacer()
                    
                    // Bottom ornament
                    HStack {
                        Spacer()
                        Text("⟐")
                            .font(.system(size: 14))
                            .foregroundColor(themeBrass.opacity(0.3))
                        Spacer()
                    }
                }
                .padding(20)
            } else {
                // Empty state
                VStack(spacing: 14) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 48))
                        .foregroundColor(WidgetPalette.textFaint)
                    Text("No journal entries yet")
                        .font(.system(size: 16))
                        .foregroundColor(WidgetPalette.textDim)
                    Text("Your journal reflections will appear here once you start writing. Open Ten Scrolls and add your first entry.")
                        .font(.system(size: 12))
                        .foregroundColor(WidgetPalette.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding()
            }
        }
    }
}

// MARK: - Accessory Widget

struct JournalWidgetAccessoryRectangularView: View {
    let entry: JournalProvider.Entry
    
    var body: some View {
        if let journalEntry = entry.selectedEntry {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: "book.closed")
                        .font(.caption2)
                    Text("Journal")
                        .font(.caption2.bold())
                }
                Text(journalEntry.text)
                    .font(.caption2)
                    .lineLimit(2)
            }
        } else {
            HStack {
                Image(systemName: "book.closed")
                Text("No journal entries")
                    .font(.caption2)
            }
        }
    }
}
