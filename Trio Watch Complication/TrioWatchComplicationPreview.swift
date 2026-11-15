import SwiftUI
import WidgetKit

#if DEBUG
    struct TrioWatchComplicationPreview: PreviewProvider {
        static var previews: some View {
            Group {
                TrioAccessoryCornerView(
                    entry: .init(
                        snapshot: TrioComplicationSnapshot(
                            glucose: "110",
                            trend: "Flat",
                            delta: "+2",
                            readingDate: Date(),
                            date: Date(),
                            glucoseColor: "#30D158"
                        )
                    )
                )
                .containerBackground(.fill.tertiary, for: .widget)
                .previewDisplayName("Recent (Green)")
                .previewContext(WidgetPreviewContext(family: .accessoryCorner))

                TrioAccessoryCornerView(
                    entry: .init(
                        snapshot: TrioComplicationSnapshot(
                            glucose: "92",
                            trend: "SingleDown",
                            delta: "-4",
                            readingDate: Date().addingTimeInterval(-4 * 60),
                            date: Date(),
                            glucoseColor: "#FF9500"
                        )
                    )
                )
                .containerBackground(.fill.tertiary, for: .widget)
                .previewDisplayName("Medium (Yellow)")
                .previewContext(WidgetPreviewContext(family: .accessoryCorner))

                TrioAccessoryCornerView(
                    entry: .init(
                        snapshot: TrioComplicationSnapshot(
                            glucose: "125",
                            trend: "SingleUp",
                            delta: "+4",
                            readingDate: Date().addingTimeInterval(-10 * 60),
                            date: Date(),
                            glucoseColor: "#30D158"
                        )
                    )
                )
                .containerBackground(.fill.tertiary, for: .widget)
                .previewDisplayName("Medium (Yellow, 10m)")
                .previewContext(WidgetPreviewContext(family: .accessoryCorner))

                TrioAccessoryCornerView(
                    entry: .init(
                        snapshot: TrioComplicationSnapshot(
                            glucose: "--",
                            trend: "",
                            delta: "--",
                            readingDate: Date().addingTimeInterval(-30 * 60),
                            date: Date(),
                            state: "--",
                            glucoseColor: nil
                        )
                    )
                )
                .containerBackground(.fill.tertiary, for: .widget)
                .previewDisplayName("Stale (Red)")
                .previewContext(WidgetPreviewContext(family: .accessoryCorner))

                TrioAccessoryCornerView(
                    entry: .init(
                        snapshot: TrioComplicationSnapshot(
                            glucose: "--",
                            trend: "",
                            delta: "--",
                            readingDate: .distantPast,
                            date: Date(),
                            state: "!!",
                            glucoseColor: nil
                        )
                    )
                )
                .containerBackground(.fill.tertiary, for: .widget)
                .previewDisplayName("Error State (!!)")
                .previewContext(WidgetPreviewContext(family: .accessoryCorner))

                TrioAccessoryCornerView(
                    entry: .init(
                        snapshot: TrioComplicationSnapshot(
                            glucose: "250",
                            trend: "DoubleUp",
                            delta: "+15",
                            readingDate: Date().addingTimeInterval(-2 * 60),
                            date: Date(),
                            glucoseColor: "#FF9500"
                        )
                    )
                )
                .containerBackground(.fill.tertiary, for: .widget)
                .previewDisplayName("High Glucose (Orange)")
                .previewContext(WidgetPreviewContext(family: .accessoryCorner))

                TrioAccessoryCornerView(
                    entry: .init(
                        snapshot: TrioComplicationSnapshot(
                            glucose: "65",
                            trend: "SingleDown",
                            delta: "-8",
                            readingDate: Date().addingTimeInterval(-1 * 60),
                            date: Date(),
                            glucoseColor: "#FF3B30"
                        )
                    )
                )
                .containerBackground(.fill.tertiary, for: .widget)
                .previewDisplayName("Low Glucose (Red)")
                .previewContext(WidgetPreviewContext(family: .accessoryCorner))
            }
        }
    }
#endif
