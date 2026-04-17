import Foundation

public struct SpendSummary: Sendable {
    public let totalEstimated: Double
    public let totalActual: Double
    public let generationCount: Int
    public let avgCostPerGeneration: Double

    public init(totalEstimated: Double, totalActual: Double,
                generationCount: Int, avgCostPerGeneration: Double) {
        self.totalEstimated = totalEstimated
        self.totalActual = totalActual
        self.generationCount = generationCount
        self.avgCostPerGeneration = avgCostPerGeneration
    }
}

public struct DailySpend: Sendable, Identifiable {
    public var id: String { bucket }
    public let bucket: String   // "2024-01-15" | "2024-03" | "2024-01"
    public let estimated: Double
    public let actual: Double

    public init(bucket: String, estimated: Double, actual: Double) {
        self.bucket = bucket
        self.estimated = estimated
        self.actual = actual
    }
}

public struct ProviderSpend: Sendable, Identifiable {
    public var id: String { providerID }
    public let providerID: String
    public let totalEstimated: Double
    public let generationCount: Int

    public init(providerID: String, totalEstimated: Double, generationCount: Int) {
        self.providerID = providerID
        self.totalEstimated = totalEstimated
        self.generationCount = generationCount
    }
}

public struct ProjectSpend: Sendable, Identifiable {
    public var id: String { projectID ?? "__unassigned__" }
    public let projectID: String?
    public let projectName: String?
    public let totalEstimated: Double
    public let generationCount: Int

    public init(projectID: String?, projectName: String?,
                totalEstimated: Double, generationCount: Int) {
        self.projectID = projectID
        self.projectName = projectName
        self.totalEstimated = totalEstimated
        self.generationCount = generationCount
    }
}

public enum SpendGranularity: String, CaseIterable, Sendable {
    case day, week, month

    public var strftimeFormat: String {
        switch self {
        case .day:   return "%Y-%m-%d"
        case .week:  return "%Y-%W"
        case .month: return "%Y-%m"
        }
    }

    public var displayName: String { rawValue.capitalized }
}
