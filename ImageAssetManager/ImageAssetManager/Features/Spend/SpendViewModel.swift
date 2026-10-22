import Foundation
import ImageAssetManagerCore

@Observable
final class SpendViewModel {

    enum DateRangePreset: String, CaseIterable {
        case thisWeek  = "This Week"
        case lastWeek  = "Last Week"
        case thisMonth = "This Month"
        case lastMonth = "Last Month"
        case custom    = "Custom"
    }

    var selectedPreset: DateRangePreset = .thisMonth
    var customStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    var customEndDate: Date = Date()
    var granularityOverride: SpendGranularity? = nil

    var summary: SpendSummary = SpendSummary(
        totalEstimated: 0, totalActual: 0,
        generationCount: 0, avgCostPerGeneration: 0
    )
    var timelineBuckets: [DailySpend] = []
    var providerBreakdown: [ProviderSpend] = []
    var projectBreakdown: [ProjectSpend] = []
    var isLoading: Bool = false

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    var effectiveDateRange: (since: String, until: String) {
        let cal = Calendar.current
        let today = Date()

        switch selectedPreset {
        case .thisWeek:
            let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)) ?? today
            let tomorrow  = cal.date(byAdding: .day, value: 1, to: today) ?? today
            return (Self.isoDate(weekStart), Self.isoDate(tomorrow))

        case .lastWeek:
            let prevWeekAnchor = cal.date(byAdding: .weekOfYear, value: -1, to: today) ?? today
            let lastWeekStart  = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: prevWeekAnchor)) ?? today
            let thisWeekStart  = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)) ?? today
            return (Self.isoDate(lastWeekStart), Self.isoDate(thisWeekStart))

        case .thisMonth:
            let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
            let tomorrow   = cal.date(byAdding: .day, value: 1, to: today) ?? today
            return (Self.isoDate(monthStart), Self.isoDate(tomorrow))

        case .lastMonth:
            let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
            let lastMonthStart = cal.date(byAdding: .month, value: -1, to: thisMonthStart) ?? today
            return (Self.isoDate(lastMonthStart), Self.isoDate(thisMonthStart))

        case .custom:
            let endExclusive = cal.date(byAdding: .day, value: 1, to: customEndDate) ?? customEndDate
            return (Self.isoDate(customStartDate), Self.isoDate(endExclusive))
        }
    }

    var effectiveGranularity: SpendGranularity {
        if let override = granularityOverride { return override }
        let (since, until) = effectiveDateRange
        let sinceDate = Self.parseIsoDate(since) ?? Date()
        let untilDate = Self.parseIsoDate(until) ?? Date()
        let days = Calendar.current.dateComponents([.day], from: sinceDate, to: untilDate).day ?? 0
        if days <= 14 { return .day }
        if days <= 90 { return .week }
        return .month
    }

    func loadData() async {
        let (since, until) = effectiveDateRange
        let granularity = effectiveGranularity
        isLoading = true
        defer { isLoading = false }
        do {
            async let s = database.fetchSpendSummary(since: since, until: until)
            async let t = database.fetchDailySpend(since: since, until: until, granularity: granularity)
            async let p = database.fetchSpendByProvider(since: since, until: until)
            async let pr = database.fetchSpendByProject(since: since, until: until)
            summary = try await s
            timelineBuckets = try await t
            providerBreakdown = try await p
            projectBreakdown = try await pr
        } catch {
            // silently show zeros on error
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func isoDate(_ date: Date) -> String { dateFormatter.string(from: date) }
    private static func parseIsoDate(_ s: String) -> Date? { dateFormatter.date(from: s) }
}
