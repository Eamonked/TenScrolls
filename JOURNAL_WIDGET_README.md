# Journal Widget Feature

## Overview

A new iOS widget that displays random journal entries from the user's Ten Scrolls journal. The widget rotates through entries automatically, showing one reflection at a time.

## Features

### Widget Sizes

1. **Small Widget (2x2)**
   - Shows journal entry text (up to 5 lines)
   - Displays date and scroll reference
   - Compact header with book icon

2. **Medium Widget (4x2)**
   - More readable text (up to 4 lines)
   - Full header with "JOURNAL REFLECTION" label
   - Date and scroll reference in header

3. **Large Widget (4x4)**
   - Maximum text display (up to 12 lines)
   - Decorative divider line
   - Bottom ornament for visual balance
   - Best for longer journal entries

4. **Lock Screen Widget (Accessory Rectangular)**
   - Compact format for lock screen
   - Shows truncated entry (2 lines)

### Rotation System

- **Automatic Rotation**: Entries rotate every 2 hours
- **Deterministic Randomness**: Uses time-based seed to ensure different entries show at different times
- **Smart Selection**: Cycles through all available entries before repeating

### Empty State

When no journal entries exist, the widget displays:
- Book icon
- "No journal entries yet" message
- Helpful prompt to start journaling

## Data Synchronization

### Widget Data Export

The main app exports journal data to shared UserDefaults:
- **Location**: `group.ekme.TenScrolls`
- **Key**: `journalWidgetData`
- **Limit**: Most recent 50 entries (to keep data size reasonable)

### Data Structure

```swift
struct JournalWidgetData {
    var entries: [JournalWidgetEntry]
    var themeId: String
    var lastUpdated: Date
}

struct JournalWidgetEntry {
    let id: String
    let text: String
    let date: String        // Short format (e.g., "Dec 15")
    let scrollRoman: String? // Roman numeral (e.g., "IV")
}
```

### When Widget Updates

The widget data is refreshed whenever:
- A new journal entry is added
- An entry is edited or deleted
- The app theme is changed
- Any state change triggers `refreshWidget()`

### Timeline Refresh

- Widget creates a 24-hour timeline with entries every 2 hours
- After 24 hours, requests a new timeline
- Manual refresh available via widget long-press → "Refresh Widget"

## Design Decisions

### Why Rotate Entries?

1. **Rediscovery**: Users rediscover past reflections they may have forgotten
2. **Motivation**: Seeing different thoughts keeps the widget fresh and engaging
3. **Privacy**: Single entry display is less overwhelming on home screen
4. **Battery**: Rotating through existing data is more efficient than live updates

### Why 2-Hour Rotation?

- **Balance**: Frequent enough to feel fresh, not so frequent it's distracting
- **Battery**: Reduces widget refresh overhead
- **Thoughtfulness**: Gives time to reflect on each entry before moving on

### Why Limit to 50 Entries?

- **Performance**: Keeps shared UserDefaults data size reasonable
- **Relevance**: Recent entries are most relevant to current practice
- **Privacy**: Limits data in shared container

## Theme Support

The widget respects the user's selected theme from the main app:
- Brass (default)
- Jade
- Crimson
- Silver
- Violet

Theme colors apply to:
- Header icon and label
- Decorative elements (dividers, ornaments)

## Technical Implementation

### Files Created/Modified

**Created:**
- `TenScrollsWidget/JournalWidget.swift` - Widget implementation
- `JOURNAL_WIDGET_README.md` - This documentation

**Modified:**
- `TenScrolls/WidgetData.swift` - Added JournalWidgetData structures
- `TenScrollsWidget/TenScrollsWidgetBundle.swift` - Added JournalWidget to bundle
- `TenScrolls/AppStore.swift` - Added journal data export in refreshWidget()

### Widget Architecture

```
JournalWidget
├── JournalProvider (TimelineProvider)
│   ├── placeholder() - Shows sample entry
│   ├── getSnapshot() - For widget gallery
│   └── getTimeline() - Creates 24-hour entry schedule
│
├── JournalWidgetEntry (TimelineEntry)
│   └── selectedEntry - Deterministically picks entry based on time
│
└── Views
    ├── JournalWidgetSmallView
    ├── JournalWidgetMediumView
    ├── JournalWidgetLargeView
    └── JournalWidgetAccessoryRectangularView
```

## User Experience

### Adding the Widget

1. Long-press on home screen
2. Tap "+" in top corner
3. Search for "Ten Scrolls"
4. Choose "Journal Reflection"
5. Select size and add to home screen

### What Users See

- **With Entries**: Random journal reflection with date and scroll context
- **Without Entries**: Encouraging message to start journaling
- **Every 2 Hours**: Different entry automatically displayed

### Privacy Considerations

- Widget only shows published (non-draft) entries
- No sensitive data (like habits or detailed logs) exposed
- Single entry view maintains privacy on shared devices
- User can hide widget or change sizes for more/less visibility

## Future Enhancements

Possible improvements:
- [ ] Filter by scroll (show only entries from specific scroll)
- [ ] Favorite entries (star system for most meaningful reflections)
- [ ] Configurable rotation frequency
- [ ] Search highlighting (if entry matches recent search)
- [ ] Interactive widget (iOS 17+) to navigate between entries
- [ ] Smart rotation (show entries from same time last year)

## Testing

To test the widget:

1. **Add Entries**: Create several journal entries in the app
2. **Add Widget**: Add the Journal Reflection widget to home screen
3. **Verify Data**: Check that entry appears with correct date/scroll
4. **Test Rotation**: Wait 2 hours or change system time to see rotation
5. **Test Empty State**: Delete all entries to verify empty state
6. **Test Themes**: Change app theme and verify widget updates
7. **Test Sizes**: Try all widget sizes (small, medium, large, lock screen)

## Support

If journal entries don't appear:
1. Check that entries are published (not drafts)
2. Force-quit and reopen the main app to trigger data sync
3. Remove and re-add the widget
4. Check iOS Settings → Ten Scrolls → Background App Refresh is enabled
