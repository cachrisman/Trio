import Charts
import CoreData
import SwiftUI

let calendar = Calendar.current

struct MainChartView: View {
    var geo: GeometryProxy
    var safeAreaSize: CGFloat
    var units: GlucoseUnits
    var hours: Int
    var highGlucose: Decimal
    var lowGlucose: Decimal
    var currentGlucoseTarget: Decimal
    var glucoseColorScheme: GlucoseColorScheme
    var screenHours: Int16
    var displayXgridLines: Bool
    var displayYgridLines: Bool
    var thresholdLines: Bool
    var state: Home.StateModel

    @State var basalProfiles: [BasalProfile] = []
    @State var preparedTempBasals: [(start: Date, end: Date, rate: Double)] = []
    @State var selection: Date? = nil

    @State var mainChartHasInitialized = false

    let now = Date.now

    private let context = CoreDataStack.shared.persistentContainer.viewContext

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.calendar) var calendar

    // Scaled spacer height for accessibility support - scales with dynamic type.
    @ScaledMetric(relativeTo: .footnote) private var axisSpacerHeight: CGFloat = 16

    private let chartSpacing: CGFloat = 5

    /// Use the current chart container height as the layout reference, then
    /// bound it to avoid pathological values during transient layout passes.
    private var chartLayoutReferenceHeight: CGFloat {
        max(geo.size.height, 0).clamped(320 ... 980)
    }
    // NOTE:
    // Historically these charts used `minHeight` to allow them to stretch if the
    // surrounding layout provided extra vertical space. The flexible sizing also
    // meant that a spacer recalculation or an unexpected safe-area change could
    // cause the charts to over-expand. We now use fixed heights to keep the
    // overlaid chart stack aligned. If future layouts need flexibility again,
    // prefer a bounded range (`minHeight` + `maxHeight`) instead of a single
    // unconstrained `minHeight`.
    var mainChartHeight: CGFloat {
        let rawHeight = chartLayoutReferenceHeight * (0.28 - safeAreaSize)
        return rawHeight.clamped(110 ... 320)
    }

    var basalChartHeight: CGFloat {
        let rawHeight = chartLayoutReferenceHeight * 0.05
        return rawHeight.clamped(24 ... 64)
    }

    var cobChartHeight: CGFloat {
        let rawHeight = chartLayoutReferenceHeight * 0.12
        return rawHeight.clamped(56 ... 150)
    }

    // Computed chart stack height to constrain the overall chart region.
    // Layout inside each VStack: basalChart, mainChart, axisSpacer, cobChart = 4 items with 3 gaps.
    private var chartStackHeight: CGFloat {
        basalChartHeight + mainChartHeight + cobChartHeight + axisSpacerHeight + (chartSpacing * 3)
    }

    var upperLimit: Decimal {
        units == .mgdL ? 400 : 22.2
    }

    private var selectedGlucose: GlucoseStored? {
        guard let selection = selection else { return nil }
        let range = selection.addingTimeInterval(-150) ... selection.addingTimeInterval(150)
        return state.glucoseFromPersistence.first { $0.date.map(range.contains) ?? false }
    }

    private func findDetermination(in range: ClosedRange<Date>) -> OrefDetermination? {
        state.enactedAndNonEnactedDeterminations.first {
            $0.deliverAt ?? now >= range.lowerBound && $0.deliverAt ?? now <= range.upperBound
        }
    }

    var selectedCOBValue: OrefDetermination? {
        guard let selection = selection else { return nil }
        let range = selection.addingTimeInterval(-150) ... selection.addingTimeInterval(150)
        return findDetermination(in: range)
    }

    var selectedIOBValue: OrefDetermination? {
        guard let selection = selection else { return nil }
        let range = selection.addingTimeInterval(-150) ... selection.addingTimeInterval(150)
        return findDetermination(in: range)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: chartSpacing) {
                    dummyBasalChart
                    staticYAxisChart
                    Color.clear.frame(height: axisSpacerHeight)
                    dummyCobChart
                }

                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(spacing: chartSpacing) {
                            basalChart
                            mainChart
                            Color.clear.frame(height: axisSpacerHeight)
                            cobIobChart
                        }.onChange(of: screenHours) {
                            scroller.scrollTo("MainChart", anchor: .trailing)
                        }
                        .onChange(of: state.glucoseFromPersistence.last?.glucose) {
                            scroller.scrollTo("MainChart", anchor: .trailing)
                            state.updateStartEndMarkers()
                        }
                        .onChange(of: state.enactedAndNonEnactedDeterminations.first?.deliverAt) {
                            scroller.scrollTo("MainChart", anchor: .trailing)
                        }
                        .onChange(of: units) {
                            // TODO: - Refactor this to only update the Y Axis Scale
                            state.setupGlucoseArray()
                        }
                        .onAppear {
                            if !mainChartHasInitialized {
                                scroller.scrollTo("MainChart", anchor: .trailing)
                                state.updateStartEndMarkers()
                                calculateTempBasalsInBackground()
                                mainChartHasInitialized = true
                            }
                        }
                    }
                }
            }
            .frame(height: chartStackHeight)
        }
    }
}

// MARK: - Main Chart with selection Popover

extension MainChartView {
    private var mainChart: some View {
        Chart {
            drawStartRuleMark()
            drawEndRuleMark()
            drawCurrentTimeMarker()

            GlucoseTargetsView(
                targetProfiles: state.targetProfiles
            )

            OverrideView(
                state: state,
                overrides: state.overrides,
                overrideRunStored: state.overrideRunStored,
                units: state.units,
                viewContext: context
            )

            TempTargetView(
                tempTargetStored: state.tempTargetStored,
                tempTargetRunStored: state.tempTargetRunStored,
                units: state.units,
                viewContext: context
            )

            GlucoseChartView(
                glucoseData: state.glucoseFromPersistence,
                units: state.units,
                highGlucose: state.highGlucose,
                lowGlucose: state.lowGlucose,
                currentGlucoseTarget: state.currentGlucoseTarget,
                isSmoothingEnabled: state.isSmoothingEnabled,
                glucoseColorScheme: state.glucoseColorScheme
            )

            InsulinView(
                glucoseData: state.glucoseFromPersistence,
                insulinData: state.insulinFromPersistence,
                units: state.units,
                bolusDisplayThreshold: state.bolusDisplayThreshold
            )

            CarbView(
                glucoseData: state.glucoseFromPersistence,
                units: state.units,
                carbData: state.carbsFromPersistence,
                fpuData: state.fpusFromPersistence,
                minValue: units == .mgdL ? state.minYAxisValue : state.minYAxisValue
                    .asMmolL
            )

            ForecastView(
                preprocessedData: state.preprocessedData,
                minForecast: state.minForecast,
                maxForecast: state.maxForecast,
                units: state.units,
                maxValue: state.maxYAxisValue,
                forecastDisplayType: state.forecastDisplayType,
                lastDeterminationDate: state.determinationsFromPersistence.first?.deliverAt ?? .distantPast
            )

            if let selectedGlucose {
                SelectionPopoverView(
                    selectedGlucose: selectedGlucose,
                    selectedIOBValue: selectedIOBValue,
                    selectedCOBValue: selectedCOBValue,
                    units: units,
                    highGlucose: highGlucose,
                    lowGlucose: lowGlucose,
                    currentGlucoseTarget: currentGlucoseTarget,
                    glucoseColorScheme: glucoseColorScheme,
                    isSmoothingEnabled: state.settingsManager.settings.smoothGlucose
                )
            }
        }
        .id("MainChart")
        .frame(height: mainChartHeight)
        .frame(width: fullWidth(viewWidth: geo.size.width))
        .chartXScale(domain: state.startMarker ... state.endMarker)
        .chartXAxis { mainChartXAxis }
        .chartYAxis { mainChartYAxis }
        .chartYAxis(.hidden)
        .chartXSelection(value: $selection)
        .chartYScale(
            domain: units == .mgdL ? state.minYAxisValue ... state.maxYAxisValue : state.minYAxisValue
                .asMmolL ... state.maxYAxisValue.asMmolL
        )
        .chartLegend(.hidden)
        .chartForegroundStyleScale([
            "iob": Color.insulin,
            "uam": Color.uam,
            "zt": Color.zt,
            "cob": Color.orange
        ])
    }
}
