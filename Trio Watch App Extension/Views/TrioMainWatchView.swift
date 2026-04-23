import Charts
import Combine
import SwiftUI
import WatchKit

struct TrioMainWatchView: View {
    @State private var state = WatchState.shared

    // misc
    @State private var currentPage: Int = 1
    @State private var rotationDegrees: Double = 0.0
    @State private var showingTempTargetSheet = false

    // view visbility
    @State private var showingTreatmentMenuSheet: Bool = false
    @State private var showingOverrideSheet: Bool = false
    // navigation flag for meal bolus combo
    @State private var continueToBolus = false
    @State private var navigationPath = NavigationPath()

    // treatments
    @State private var selectedTreatment: TreatmentOption?

    // complication progress ring — 1 Hz tick only while page 2 is visible (see `maintainRingRefreshTimer`)
    @State private var ringRefreshTick = Date()
    private let ringRefreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var arcReferenceReadingDate: Date? {
        state.g7DebugManager.lastReadingDate
            ?? TrioComplicationDataStore.shared.latestSnapshot()?.readingDate
    }

    var isWatchStateDated: Bool {
        // `lastWatchStateUpdate` is WC-only monotonic; main UI freshness uses `effectiveWatchUiFreshnessAt`
        // (phone state time vs direct-BLE / complication hydration wall times).
        guard let lastUpdateTimestamp = state.effectiveWatchUiFreshnessAt else {
            return true
        }
        let now = Date()
        let secondsSinceUpdate = now.timeIntervalSince(lastUpdateTimestamp)
        // Return true if last update older than 5 min, so 1 loop cycle
        return secondsSinceUpdate > 5 * 60
    }

    var isSessionUnreachable: Bool {
        guard let session = state.session else {
            return true // No session at all => unreachable
        }
        // Return true if not .activated OR not reachable
        return session.activationState != .activated
    }

    // Active adjustment indicator
    private func isAdjustmentActive<T>(for presets: [T], predicate: (T) -> Bool) -> Bool {
        let sortedPresets = presets.sorted { predicate($0) && !predicate($1) }
        return !sortedPresets.isEmpty && sortedPresets.first(where: predicate) != nil
    }

    private var isTempTargetActive: Bool {
        isAdjustmentActive(for: state.tempTargetPresets) { $0.isEnabled }
    }

    private var isOverrideActive: Bool {
        isAdjustmentActive(for: state.overridePresets) { $0.isEnabled }
    }

    private var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TabView(selection: $currentPage) {
                // Page 1: Glucose chart
                Group {
                    if currentPage == 0 {
                        GlucoseChartView(
                            glucoseValues: state.glucoseValues,
                            minYAxisValue: state.minYAxisValue,
                            maxYAxisValue: state.maxYAxisValue
                        )
                    } else {
                        Color.clear
                    }
                }
                .tag(0)

                // Page 2: Current glucose trend in "BG bobble"
                ZStack {
                    GlucoseTrendView(
                        state: state,
                        rotationDegrees: rotationDegrees,
                        isWatchStateDated: isWatchStateDated || isSessionUnreachable
                    )

                    if state.showSyncingAnimation {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.primary, Color.tabBar, Color.clear)
                            .symbolEffect(
                                .variableColor.iterative,
                                options: .repeating,
                                value: state.showSyncingAnimation
                            )
                            .position(
                                x: 20,
                                y: (WKInterfaceDevice.current().screenBounds.height / 4) -
                                    7 // Font .body == 14, so half of default size for the SF Symbol image
                            )
                    }
                }
                .tag(1)

                // Page 3: Complication Debug View (only constructed when visible)
                Group {
                    if currentPage == 2 {
                        ComplicationDebugView()
                    } else {
                        Color.clear
                    }
                }
                .tag(2)
            }
            .onAppear {
                Task {
                    await WatchLogger.shared.log("Watch main view appeared")
                }

                let cachedSnapshot = TrioComplicationDataStore.shared.latestSnapshot()
                let hasValidWatchData = state.currentGlucose != "--" && !state.currentGlucose.isEmpty
                if !hasValidWatchData, let snapshot = cachedSnapshot {
                    state.currentGlucose = snapshot.glucose
                    state.trend = snapshot.trend
                    state.delta = snapshot.delta
                    if let glucoseColor = snapshot.glucoseColor {
                        state.currentGlucoseColorString = glucoseColor
                    }
                    state.noteComplicationSnapshotUiFreshness(snapshot)
                    state.showSyncingAnimation = true
                } else if let snapshot = cachedSnapshot,
                          snapshot.readingDate > (state.lastDirectBleAppliedReadingDate ?? .distantPast)
                {
                    state.currentGlucose = snapshot.glucose
                    state.trend = snapshot.trend
                    state.delta = snapshot.delta
                    if let glucoseColor = snapshot.glucoseColor {
                        state.currentGlucoseColorString = glucoseColor
                    }
                    state.noteComplicationSnapshotUiFreshness(snapshot)
                    state.showSyncingAnimation = false
                }

                state.bolusAmount = 0
                state.recommendedBolus = 0

                state.noteMainWatchRootViewAppearedForResidentTelemetry()
            }
            .onChange(of: currentPage) { _, newPage in
                if newPage == 0 {
                    state.noteChartTabBecameVisibleForResidentTelemetry()
                }
            }
            .background(trioBackgroundColor)
            .tabViewStyle(.page(indexDisplayMode: .always))
            .onChange(of: state.trend) { _, newTrend in
                withAnimation {
                    updateRotation(for: newTrend)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    VStack {
                        Image(systemName: "syringe.fill")
                            .foregroundStyle(Color.insulin)

                        Text(isWatchStateDated || isSessionUnreachable ? "--" : state.iob ?? "--")
                            .foregroundStyle(isWatchStateDated ? Color.secondary : Color.white)
                            .frame(alignment: .leading)
                            .minimumScaleFactor(0.5)
                    }.font(.caption2)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    VStack {
                        Image(systemName: "fork.knife")
                            .foregroundStyle(Color.orange)

                        Text(isWatchStateDated || isSessionUnreachable ? "--" : state.cob ?? "--")
                            .foregroundStyle(isWatchStateDated || isSessionUnreachable ? Color.secondary : Color.white)
                            .frame(alignment: .trailing)
                            .minimumScaleFactor(0.5)
                    }.font(.caption2)
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    if currentPage == 1 {
                        Button {
                            showingOverrideSheet = true
                        } label: {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .foregroundStyle(Color.primary, isOverrideActive ? Color.primary : Color.purple)
                        }
                        .tint(isOverrideActive ? Color.purple : nil)
                        .disabled(isWatchStateDated || isSessionUnreachable)

                        Button {
                            showingTreatmentMenuSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(Color.bgDarkerDarkBlue)
                        }
                        .controlSize(.large)
                        .buttonStyle(WatchOSButtonStyle(deviceType: state.deviceType))
                        .disabled(isWatchStateDated || isSessionUnreachable)

                        Button {
                            showingTempTargetSheet = true
                        } label: {
                            Image(systemName: "target")
                                .foregroundStyle(isTempTargetActive ? Color.primary : Color.loopGreen.opacity(0.75))
                        }
                        .tint(isTempTargetActive ? Color.loopGreen.opacity(0.75) : nil)
                        .disabled(isWatchStateDated || isSessionUnreachable)
                    }
                }
            }
            .fullScreenCover(isPresented: $showingTreatmentMenuSheet) {
                TreatmentMenuView(deviceType: state.deviceType, selectedTreatment: $selectedTreatment) {
                    handleTreatmentSelection()
                }
                .onAppear {
                    // reset the conditional navigation flag when opening
                    continueToBolus = false
                }
            }
            .sheet(isPresented: $showingOverrideSheet) {
                OverridePresetsView(
                    state: state,
                    overridePresets: state.overridePresets
                ) {
                    showingOverrideSheet = false
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .sheet(isPresented: $showingTempTargetSheet) {
                TempTargetPresetsView(
                    state: state,
                    tempTargetPresets: state.tempTargetPresets
                ) {
                    showingTempTargetSheet = false
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .navigationDestination(for: NavigationDestinations.self) { destination in
                switch destination {
                case .acknowledgmentPending:
                    AcknowledgementPendingView(
                        navigationPath: $navigationPath,
                        state: state,
                        shouldNavigateToRoot: $state.shouldNavigateToRoot
                    )
                case .carbsInput:
                    CarbsInputView(
                        navigationPath: $navigationPath,
                        state: state,
                        continueToBolus: continueToBolus
                    )
                case .bolusInput:
                    BolusInputView(
                        navigationPath: $navigationPath,
                        state: state
                    )
                case .bolusConfirm:
                    BolusConfirmationView(
                        navigationPath: $navigationPath,
                        state: state,
                        bolusAmount: $state.bolusAmount,
                        confirmationProgress: $state.confirmationProgress
                    )
                }
            }
            .onChange(of: navigationPath) { _, newPath in
                if newPath.isEmpty {
                    // Reset conditional view navigation when returning to root view
                    continueToBolus = false
                }
            }
        }
        .ignoresSafeArea()
        .overlay {
            if currentPage == 2 {
                if #available(watchOS 26.0, *) {
                    ProgressRingView(
                        arcReferenceReadingDate: arcReferenceReadingDate,
                        tick: ringRefreshTick
                    )
                }
            }
        }
        .onReceive(ringRefreshTimer) { date in
            if currentPage == 2 { ringRefreshTick = date }
        }
    }

    private func updateRotation(for trend: String?) {
        switch trend {
        case "DoubleUp",
             "SingleUp":
            rotationDegrees = -90
        case "FortyFiveUp":
            rotationDegrees = -45
        case "Flat":
            rotationDegrees = 0
        case "FortyFiveDown":
            rotationDegrees = 45
        case "DoubleDown",
             "SingleDown":
            rotationDegrees = 90
        default:
            rotationDegrees = 0
        }
    }

    private func handleTreatmentSelection() {
        showingTreatmentMenuSheet = false // Dismiss the sheet

        guard let treatment = selectedTreatment else { return }

        switch treatment {
        case .meal:
            navigationPath.append(NavigationDestinations.carbsInput)
        case .bolus:
            // Reset carbs amount when directly going to bolus input
            state.carbsAmount = 0
            navigationPath.append(NavigationDestinations.bolusInput)
        case .mealBolusCombo:
            continueToBolus = true // Explicitely set subsequent view navigation
            navigationPath.append(NavigationDestinations.carbsInput)
        }
    }
}

#Preview {
    TrioMainWatchView()
}
