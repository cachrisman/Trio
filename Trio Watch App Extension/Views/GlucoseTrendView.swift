import SwiftUI

struct GlucoseTrendView: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    /// Determines the status color based on the time elapsed since the last loop
    /// - Parameter timeString: The time string representing minutes since last loop (format: "X min")
    /// - Returns: A color indicating the status:
    ///   - Green: <= 5 minutes
    ///   - Yellow: 5-10 minutes
    ///   - Red: > 10 minutes or invalid time
    private func statusColor(for timeString: String?) -> Color {
        guard let timeString = timeString,
              timeString != "--",
              let minutes = timeString.split(separator: " ").first.flatMap({ Int($0) })
        else {
            return Color.secondary
        }

        guard !isWatchStateDated else {
            return Color.secondary
        }

        switch minutes {
        case ...5:
            return Color.loopGreen
        case 5 ... 10:
            return Color.loopYellow
        case 11...:
            return Color.loopRed
        default:
            return Color.secondary
        }
    }

    var circleSize: CGFloat {
        switch state.deviceType {
        case .watch40mm:
            return 82
        case .watch41mm,
             .watch42mm:
            return 86
        case .watch44mm:
            return 96
        case .unknown,
             .watch45mm:
            return 103
        case .watch49mm:
            return 105
        }
    }

    var lineWidth: CGFloat {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm,
             .watch42mm,
             .watch44mm:
            return 1
        case .unknown,
             .watch45mm:
            return 1.5
        case .watch49mm:
            return 1.5
        }
    }

    var shadowRadius: CGFloat {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm,
             .watch42mm:
            return 8
        case .watch44mm:
            return 9
        case .unknown,
             .watch45mm:
            return 12
        case .watch49mm:
            return 12
        }
    }

    var currentGlucoseFontSize: Font {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm,
             .watch42mm,
             .watch44mm:
            return .title2
        case .unknown,
             .watch45mm:
            return .title
        case .watch49mm:
            return .title
        }
    }

    var minutesAgoFontSize: CGFloat {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm:
            return 9
        case .unknown,
             .watch42mm,
             .watch44mm:
            return 10
        case .watch45mm:
            return 11
        case .watch49mm:
            return 10
        }
    }

    private var sourceAbbrev: String {
        switch state.displayedComplicationDataSource {
        case .g7DirectBLE: "BLE"
        case .watchConnectivityPhone: "Phone"
        case .healthKit: "HK"
        case .unknown: "…"
        }
    }

    private var bleStateAbbrev: String {
        switch state.g7DirectBLEStatus {
        case .off: "off"
        case .searching: "scan"
        case .connecting: "conn"
        case .active: "ok"
        case .stalled: "stall"
        case .unavailable: "noBT"
        }
    }

    private var lastBleRecency: String? {
        guard let d = state.lastG7DirectBLEEventDate else { return nil }
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "<1m" }
        let m = s / 60
        if m < 120 { return "\(m)m" }
        return "\(m/60)h+"
    }

    private var recencyLine: String {
        if isWatchStateDated {
            return String(localized: "STALE DATA", comment: "Information displayed when watch app data outdated or stale.")
        }
        let base = state.lastLoopTime ?? "--"
        let path = "· src:\(sourceAbbrev)"
        let ble = " · G7:\(bleStateAbbrev)\(lastBleRecency.map { "[\($0)]" } ?? "")"
        return "\(base)\(path)\(ble)"
    }

    var body: some View {
        VStack {
            ZStack {
                Circle()
                    .stroke(statusColor(for: state.lastLoopTime), lineWidth: lineWidth)
                    .frame(width: circleSize, height: circleSize)
                    .background(Circle().fill(Color.bgDarkBlue))
                    .shadow(color: statusColor(for: state.lastLoopTime), radius: shadowRadius)

                TrendShape(
                    isWatchStateDated: isWatchStateDated,
                    rotationDegrees: rotationDegrees,
                    deviceType: state.deviceType
                )
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: rotationDegrees)
                .shadow(color: Color.black.opacity(0.5), radius: 5)

                VStack(alignment: .center) {
                    Text(isWatchStateDated ? "--" : state.currentGlucose)
                        .fontWeight(.semibold)
                        .font(currentGlucoseFontSize)
                        .foregroundStyle(isWatchStateDated ? Color.secondary : state.currentGlucoseColorString.toColor())

                    if let delta = state.delta {
                        Text(isWatchStateDated ? "--" : delta)
                            .fontWeight(.semibold)
                            .font(.system(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(recencyLine)
            .font(.system(size: minutesAgoFontSize - 1))
            .lineLimit(2)
            .minimumScaleFactor(0.55)
            .fontWidth(isWatchStateDated ? .expanded : .standard)

            Spacer()

        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
