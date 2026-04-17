#if os(macOS)
import SwiftUI
import Charts
import ImageAssetManagerCore

struct SpendByProviderChart: View {
    let providers: [ProviderSpend]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By Provider")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.appTextSecondary)
                .textCase(.uppercase)

            if providers.isEmpty {
                emptyState
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        Chart(providers) { provider in
            BarMark(
                x: .value("Spend", provider.totalEstimated),
                y: .value("Provider", provider.providerID)
            )
            .foregroundStyle(Color.appAccent)
            .cornerRadius(3)
            .annotation(position: .trailing, alignment: .leading) {
                Text(String(format: "$%.4f", provider.totalEstimated))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .chartXAxis {
            AxisMarks(format: .currency(code: "USD").precision(.fractionLength(4)))
        }
        .chartPlotStyle { area in
            area.background(Color.appSurface)
        }
        .frame(height: max(60, CGFloat(providers.count) * 36))
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.appSurfaceRaised)
            .frame(height: 60)
            .overlay {
                Text("No data")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)
            }
    }
}
#endif
