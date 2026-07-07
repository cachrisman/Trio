import Charts
import SwiftUI
import WatchKit

struct TrioMainWatchView: View {
    @State private var state = WatchState.shared

    // misc
    /// Tab order: 0 = chart (left), 1 = main glucose (center), 2 = debug (right).
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

    var isWatchStateDated: Bool {
        // If `lastWatchStateUpdate` is nil, treat as "dated"
        guard let lastUpdateTimestamp = state.lastWatchStateUpdate else {
            return true
        }
        let now = Date()
        let secondsSinceUpdate = now.timeIntervalSince(lastUpdateTimestamp)
        // Return true if last update older than 5 min, so 1 loop cycle
        return secondsSinceUpdate > 5 * 60
    }

    var isPhoneCommandUnavailable: Bool {
        guard let session = state.session else {
            return true // No session at all => unreachable
        }
        return session.activationState != .activated || !session.isReachable
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
                // Page 0: Glucose chart (swipe right from main)
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

                // Page 1: Current glucose trend in "BG bobble" (default)
                ZStack {
                    GlucoseTrendView(
                        state: state,
                        rotationDegrees: rotationDegrees,
                        // Do NOT OR with `isPhoneCommandUnavailable` here: G7 direct BLE and
                        // HealthKit both update `lastWatchStateUpdate` without phone
                        // involvement, so the 5-minute `isWatchStateDated` window is the
                        // authoritative freshness check for the glucose bubble. Blanking
                        // on phone unreachability would hide a fresh BLE/HK reading.
                        // Treatment buttons + IOB/COB rows below still gate on
                        // `isPhoneCommandUnavailable` because those values come from the phone.
                        isWatchStateDated: isWatchStateDated
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

                // Page 2: Complication Debug View (only constructed when visible)
                Group {
                    if currentPage == 2 {
                        WatchDiagnosticsView()
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
                    state.alignDisplayedReadingAttributionWithComplicationSnapshot(snapshot)
                    if let glucoseColor = snapshot.glucoseColor {
                        state.currentGlucoseColorString = glucoseColor
                    }
                    state.lastWatchStateUpdate = snapshot.readingDate
                    state.showSyncingAnimation = true
                } else if let snapshot = cachedSnapshot,
                          let lastUpdate = state.lastWatchStateUpdate,
                          snapshot.readingDate > lastUpdate
                {
                    state.currentGlucose = snapshot.glucose
                    state.trend = snapshot.trend
                    state.delta = snapshot.delta
                    state.alignDisplayedReadingAttributionWithComplicationSnapshot(snapshot)
                    if let glucoseColor = snapshot.glucoseColor {
                        state.currentGlucoseColorString = glucoseColor
                    }
                    state.lastWatchStateUpdate = snapshot.readingDate
                    state.showSyncingAnimation = false
                }

                // Build 205 / W2: populate the chart from the persisted 24h history on startup, so it
                // isn't blank until the first WC payload. Only when empty (a fresh payload wins).
                if state.glucoseValues.isEmpty {
                    state.glucoseValues = WatchGlucoseHistoryStore.shared.loadAsDisplayValues(
                        colorComputer: WatchGlucoseColorComputer.shared
                    )
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
            .tabViewStyle(.page)
            .digitalCrownRotation($currentPage.doubleBinding(), from: 0, through: 2, by: 1)
            .onChange(of: state.trend) { _, newTrend in
                withAnimation {
                    updateRotation(for: newTrend)
                }
            }
            .toolbar {
                if currentPage != 2 {
                    ToolbarItem(placement: .topBarLeading) {
                        VStack {
                            Image(systemName: "syringe.fill")
                                .foregroundStyle(Color.insulin)

                            Text(isWatchStateDated ? "--" : state.iob ?? "--") // W4: phone-reachability gates buttons, not data
                                .foregroundStyle(isWatchStateDated ? Color.secondary : Color.white)
                                .frame(alignment: .leading)
                                .minimumScaleFactor(0.5)
                        }.font(.caption2)
                    }
                }

                if currentPage != 2 {
                    ToolbarItem(placement: .topBarTrailing) {
                        VStack {
                            Image(systemName: "fork.knife")
                                .foregroundStyle(Color.orange)

                            Text(isWatchStateDated ? "--" : state.cob ?? "--") // W4: phone-reachability gates buttons, not data
                                .foregroundStyle(isWatchStateDated ? Color.secondary : Color.white)
                                    .frame(alignment: .trailing)
                                    .minimumScaleFactor(0.5)
                        }.font(.caption2)
                    }
                }

                if currentPage != 2 {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            showingOverrideSheet = true
                        } label: {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .foregroundStyle(Color.primary, isOverrideActive ? Color.primary : Color.purple)
                        }
                        .tint(isOverrideActive ? Color.purple : nil)
                        .disabled(isWatchStateDated || isPhoneCommandUnavailable)

                        Button {
                            showingTreatmentMenuSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(Color.bgDarkerDarkBlue)
                        }
                        .controlSize(.large)
                        .buttonStyle(WatchOSButtonStyle(deviceType: state.deviceType))
                        .disabled(isWatchStateDated || isPhoneCommandUnavailable)

                        Button {
                            showingTempTargetSheet = true
                        } label: {
                            Image(systemName: "target")
                                .foregroundStyle(isTempTargetActive ? Color.primary : Color.loopGreen.opacity(0.75))
                        }
                        .tint(isTempTargetActive ? Color.loopGreen.opacity(0.75) : nil)
                        .disabled(isWatchStateDated || isPhoneCommandUnavailable)
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
