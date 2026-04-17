import SwiftUI
import ImageAssetManagerCore

struct SpendDashboardView: View {
    @Bindable var viewModel: SpendViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryCards

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    DateRangePickerView(viewModel: viewModel)
                    #if os(macOS)
                    granularityPicker
                    #endif
                }

                Divider()

                #if os(macOS)
                SpendTimelineChart(
                    buckets: viewModel.timelineBuckets,
                    granularity: viewModel.effectiveGranularity
                )
                Divider()
                #endif

                breakdownSection
            }
            .padding(16)
        }
        .background(Color.appBackground)
        .overlay(alignment: .center) {
            if viewModel.isLoading {
                ProgressView().tint(Color.appAccent)
            }
        }
        .task { await viewModel.loadData() }
        .onChange(of: viewModel.selectedPreset) { _, _ in
            Task { await viewModel.loadData() }
        }
        .onChange(of: viewModel.customStartDate) { _, _ in
            guard viewModel.selectedPreset == .custom else { return }
            Task { await viewModel.loadData() }
        }
        .onChange(of: viewModel.customEndDate) { _, _ in
            guard viewModel.selectedPreset == .custom else { return }
            Task { await viewModel.loadData() }
        }
        .onChange(of: viewModel.granularityOverride) { _, _ in
            Task { await viewModel.loadData() }
        }
    }

    @ViewBuilder
    private var summaryCards: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            statCard("Est. Spend", String(format: "$%.4f", viewModel.summary.totalEstimated))
            statCard("Actual", viewModel.summary.totalActual > 0
                ? String(format: "$%.4f", viewModel.summary.totalActual) : "—")
            statCard("Generations", "\(viewModel.summary.generationCount)")
            statCard("Avg / Gen", String(format: "$%.4f", viewModel.summary.avgCostPerGeneration))
        }
        #else
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            statCard("Est. Spend", String(format: "$%.4f", viewModel.summary.totalEstimated))
            statCard("Actual", viewModel.summary.totalActual > 0
                ? String(format: "$%.4f", viewModel.summary.totalActual) : "—")
            statCard("Generations", "\(viewModel.summary.generationCount)")
            statCard("Avg / Gen", String(format: "$%.4f", viewModel.summary.avgCostPerGeneration))
        }
        #endif
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Color.appTextSecondary)
                .textCase(.uppercase)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(Color.appTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    #if os(macOS)
    private var granularityPicker: some View {
        HStack(spacing: 8) {
            Text("Granularity")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
            Picker("", selection: Binding(
                get: {
                    guard let o = viewModel.granularityOverride else { return "Auto" }
                    return o.displayName
                },
                set: { value in
                    switch value {
                    case "Day":   viewModel.granularityOverride = .day
                    case "Week":  viewModel.granularityOverride = .week
                    case "Month": viewModel.granularityOverride = .month
                    default:      viewModel.granularityOverride = nil
                    }
                }
            )) {
                Text("Auto").tag("Auto")
                ForEach(SpendGranularity.allCases, id: \.self) { g in
                    Text(g.displayName).tag(g.displayName)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        }
    }
    #endif

    @ViewBuilder
    private var breakdownSection: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                SpendByProviderChart(providers: viewModel.providerBreakdown)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                projectBreakdownList
            }
            .frame(maxWidth: .infinity)
        }
        #else
        VStack(alignment: .leading, spacing: 16) {
            providerBreakdownList
            Divider()
            projectBreakdownList
        }
        #endif
    }

    private var projectBreakdownList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By Project")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.appTextSecondary)
                .textCase(.uppercase)

            if viewModel.projectBreakdown.isEmpty {
                Text("No data for this period")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                ForEach(viewModel.projectBreakdown) { project in
                    HStack(spacing: 8) {
                        Text(project.projectName ?? "Unassigned")
                            .font(.callout)
                            .foregroundStyle(Color.appTextPrimary)
                        Spacer()
                        Text("\(project.generationCount) gen")
                            .font(.caption2)
                            .foregroundStyle(Color.appTextSecondary)
                        Text(String(format: "$%.4f", project.totalEstimated))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.appTextPrimary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    #if !os(macOS)
    private var providerBreakdownList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By Provider")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.appTextSecondary)
                .textCase(.uppercase)

            if viewModel.providerBreakdown.isEmpty {
                Text("No data for this period")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                ForEach(viewModel.providerBreakdown) { provider in
                    HStack(spacing: 8) {
                        Text(provider.providerID)
                            .font(.callout)
                            .foregroundStyle(Color.appTextPrimary)
                        Spacer()
                        Text("\(provider.generationCount) gen")
                            .font(.caption2)
                            .foregroundStyle(Color.appTextSecondary)
                        Text(String(format: "$%.4f", provider.totalEstimated))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.appTextPrimary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
    #endif
}
