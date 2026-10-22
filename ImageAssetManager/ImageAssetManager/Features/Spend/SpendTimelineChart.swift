#if os(macOS)
import SwiftUI
import Charts
import ImageAssetManagerCore

struct SpendTimelineChart: View {
    let buckets: [DailySpend]
    let granularity: SpendGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spend Over Time")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.appTextSecondary)
                .textCase(.uppercase)

            if buckets.isEmpty {
                emptyState
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(buckets) { bucket in
                AreaMark(
                    x: .value("Period", bucket.bucket),
                    y: .value("Estimated", bucket.estimated)
                )
                .foregroundStyle(Color.appAccent.opacity(0.12))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Period", bucket.bucket),
                    y: .value("Estimated", bucket.estimated)
                )
                .foregroundStyle(Color.appAccent)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
                .symbol(.circle)
                .symbolSize(16)

                if bucket.actual > 0 {
                    LineMark(
                        x: .value("Period", bucket.bucket),
                        y: .value("Actual", bucket.actual)
                    )
                    .foregroundStyle(Color.appTextSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.catmullRom)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(format: .currency(code: "GBP").precision(.fractionLength(4)))
        }
        .chartPlotStyle { area in
            area.background(Color.appSurface)
        }
        .frame(height: 180)
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.appSurfaceRaised)
            .frame(height: 180)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.appTextSecondary)
                        .accessibilityHidden(true)
                    Text("No data for this period")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
    }
}
#endif
