# Trio Watch Complication Documentation

## Overview

The Trio Watch complication provides a compact, always-visible glucose monitoring display in the watch face corner. It uses color-coding and automatic updates to show both the current glucose value and data freshness.

## Implementation Details

### Data Flow
1. iPhone receives push notification with new glucose data
2. Data transferred to watch via WCSession
3. Watch stores data in shared App Group container
4. WidgetKit reloads timeline
5. Complication updates display

### Display Components

#### Top Line (Outer)
- Glucose value + trend arrow
- Example: "110 →"
- Bold, rounded font for clarity

#### Bottom Line (Inner)
- Delta + relative time
- Example: "+2 • 5m"
- Color-coded bullet and time for freshness

### Freshness Indicators

Time windows and colors:
- < 5 minutes: 🟢 Green (fresh)
- 5-15 minutes: 🟡 Yellow (medium)
- > 15 minutes: 🔴 Red (stale)

### Update Mechanisms

1. Data Updates (every 5 minutes)
- New glucose readings via WCSession
- Background refresh tasks
- Manual updates when app opens

2. Display Updates (every minute)
- TimelineView refreshes to update age indicator
- Colors transition automatically
- No background task needed

### Error States

The complication handles various error states:
- No data: Shows "--"
- Invalid readings: Fallback to safe display
- Connection issues: Red timing indicator

## Key Files

1. `TrioWatchComplication.swift`
   - Main complication configuration
   - Timeline provider
   - View layouts

2. `TrioComplicationDataStore.swift`
   - Data persistence
   - Shared storage access
   - Timeline reloading

3. `ExtensionDelegate.swift`
   - Background refresh scheduling
   - Lifecycle management

4. `WatchState.swift`
   - WatchConnectivity handling
   - Data synchronization

## Testing

Use the preview provider in `TrioWatchComplicationPreview.swift` to verify:
1. Fresh data display
2. Medium-age display
3. Stale data display
4. Error states