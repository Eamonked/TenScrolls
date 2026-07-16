import WidgetKit
import SwiftUI

struct TenScrollsWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            WidgetSmallView(data: entry.data)
        case .systemMedium:
            WidgetMediumView(data: entry.data)
        case .systemLarge:
            WidgetMediumView(data: entry.data)
        case .systemExtraLarge:
            WidgetMediumView(data: entry.data)
        case .accessoryCircular:
            WidgetAccessoryCircularView(data: entry.data)
        case .accessoryRectangular:
            WidgetAccessoryRectangularView(data: entry.data)
        case .accessoryInline:
            WidgetAccessoryRectangularView(data: entry.data)
        @unknown default:
            WidgetSmallView(data: entry.data)
        }
    }
}

struct WidgetSmallView: View {
    let data: WidgetData
    
    var themeBrass: Color { WidgetPalette.themeBrass(for: data.themeId) }
    
    var body: some View {
        ZStack {
            WidgetPalette.background.ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 14) {
                // Streak
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").font(.system(size: 14))
                    Text("\(data.streak)").font(.system(size: 16, weight: .bold, design: .monospaced))
                }
                .foregroundColor(themeBrass)
                
                Spacer()
                
                // Stamps
                HStack(spacing: 8) {
                    WidgetStamp(done: data.dawnComplete, icon: "sunrise.fill", color: themeBrass)
                    WidgetStamp(done: data.middayComplete, icon: "sun.max.fill", color: themeBrass)
                    WidgetStamp(done: data.duskComplete, icon: "sunset.fill", color: themeBrass)
                }
            }
            .padding()
        }
    }
}

struct WidgetMediumView: View {
    let data: WidgetData
    
    var themeBrass: Color { WidgetPalette.themeBrass(for: data.themeId) }
    
    var body: some View {
        ZStack {
            WidgetPalette.background.ignoresSafeArea()
            
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SCROLL \(data.activeScrollRoman)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(themeBrass)
                    
                    Text(data.activeScrollTitle.isEmpty ? "Active Practice" : data.activeScrollTitle)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundColor(WidgetPalette.text)
                        .lineLimit(2)
                    
                    Text("\(data.daysCompletedOnActive) / 30 DAYS")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(WidgetPalette.textFaint)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 14) {
                    // Streak
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill").font(.system(size: 14))
                        Text("\(data.streak)").font(.system(size: 16, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(themeBrass)
                    
                    Spacer()
                    
                    // Stamps
                    HStack(spacing: 8) {
                        WidgetStamp(done: data.dawnComplete, icon: "sunrise.fill", color: themeBrass)
                        WidgetStamp(done: data.middayComplete, icon: "sun.max.fill", color: themeBrass)
                        WidgetStamp(done: data.duskComplete, icon: "sunset.fill", color: themeBrass)
                    }
                }
            }
            .padding()
        }
    }
}

struct WidgetAccessoryCircularView: View {
    let data: WidgetData
    
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 2) {
                Image(systemName: "flame.fill").font(.system(size: 12))
                Text("\(data.streak)").font(.system(size: 16, weight: .bold, design: .monospaced))
            }
        }
    }
}

struct WidgetAccessoryRectangularView: View {
    let data: WidgetData
    
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text("Ten Scrolls").font(.headline)
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                    Text("\(data.streak)")
                }
                .font(.subheadline)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: data.dawnComplete ? "circle.fill" : "circle")
                Image(systemName: data.middayComplete ? "circle.fill" : "circle")
                Image(systemName: data.duskComplete ? "circle.fill" : "circle")
            }
            .font(.system(size: 12))
        }
    }
}

struct WidgetStamp: View {
    let done: Bool
    let icon: String
    let color: Color
    
    var body: some View {
        ZStack {
            Circle()
                .fill(done ? color : WidgetPalette.ink3)
                .overlay(Circle().stroke(done ? color : WidgetPalette.inkLine, lineWidth: 1))
                .frame(width: 32, height: 32)
            
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(done ? WidgetPalette.background : WidgetPalette.textDim)
        }
    }
}

// MARK: - Colors

extension Color {
    init(widgetHex hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

enum WidgetPalette {
    static let ink = Color(widgetHex: "12161B")
    static let ink2 = Color(widgetHex: "1A2028")
    static let ink3 = Color(widgetHex: "232B35")
    static let inkLine = Color(widgetHex: "293240")
    static let text = Color(widgetHex: "EDEAE2")
    static let textDim = Color(widgetHex: "8F97A3")
    static let textFaint = Color(widgetHex: "5B6270")
    static let background = Color(widgetHex: "05070A")
    
    static let brass = Color(widgetHex: "C4903F")
    
    static func themeBrass(for id: String) -> Color {
        switch id {
        case "jade": return Color(widgetHex: "3F8C63")
        case "crimson": return Color(widgetHex: "B2454A")
        case "silver": return Color(widgetHex: "8A93A0")
        case "violet": return Color(widgetHex: "7A5FB0")
        default: return brass
        }
    }
}
