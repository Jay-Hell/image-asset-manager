import GRDB
import Foundation

extension AppDatabase {

    public func fetchSpendSummary(since: String, until: String) async throws -> SpendSummary {
        let sql = """
            SELECT
                COALESCE(SUM(estimated_cost), 0) AS total_estimated,
                COALESCE(SUM(actual_cost), 0)    AS total_actual,
                COUNT(*)                          AS generation_count
            FROM spend_log
            WHERE timestamp >= ? AND timestamp < ?
            """
        let args: StatementArguments = [since, until]
        return try await read { db in
            let row = try Row.fetchOne(db, sql: sql, arguments: args)
            let total = (row?["total_estimated"] as? Double) ?? 0
            let count = (row?["generation_count"] as? Int) ?? 0
            return SpendSummary(
                totalEstimated: total,
                totalActual: (row?["total_actual"] as? Double) ?? 0,
                generationCount: count,
                avgCostPerGeneration: count > 0 ? total / Double(count) : 0
            )
        }
    }

    public func fetchDailySpend(
        since: String,
        until: String,
        granularity: SpendGranularity
    ) async throws -> [DailySpend] {
        let fmt = granularity.strftimeFormat
        let sql = """
            SELECT
                strftime('\(fmt)', timestamp) AS bucket,
                COALESCE(SUM(estimated_cost), 0) AS estimated,
                COALESCE(SUM(actual_cost), 0)    AS actual
            FROM spend_log
            WHERE timestamp >= ? AND timestamp < ?
            GROUP BY bucket
            ORDER BY bucket
            """
        let args: StatementArguments = [since, until]
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.compactMap { row -> DailySpend? in
                guard let bucket = row["bucket"] as? String else { return nil }
                return DailySpend(
                    bucket: bucket,
                    estimated: (row["estimated"] as? Double) ?? 0,
                    actual: (row["actual"] as? Double) ?? 0
                )
            }
        }
    }

    public func fetchSpendByProvider(since: String, until: String) async throws -> [ProviderSpend] {
        let sql = """
            SELECT
                provider_id,
                COALESCE(SUM(estimated_cost), 0) AS total_estimated,
                COUNT(*) AS generation_count
            FROM spend_log
            WHERE timestamp >= ? AND timestamp < ?
            GROUP BY provider_id
            ORDER BY total_estimated DESC
            """
        let args: StatementArguments = [since, until]
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.compactMap { row -> ProviderSpend? in
                guard let pid = row["provider_id"] as? String else { return nil }
                return ProviderSpend(
                    providerID: pid,
                    totalEstimated: (row["total_estimated"] as? Double) ?? 0,
                    generationCount: (row["generation_count"] as? Int) ?? 0
                )
            }
        }
    }

    public func fetchSpendByProject(since: String, until: String) async throws -> [ProjectSpend] {
        let sql = """
            SELECT
                p.id AS project_id,
                p.name AS project_name,
                COALESCE(SUM(sl.estimated_cost), 0) AS total_estimated,
                COUNT(*) AS generation_count
            FROM spend_log sl
            LEFT JOIN assets a ON a.id = sl.asset_id
            LEFT JOIN projects p ON p.id = a.project_id
            WHERE sl.timestamp >= ? AND sl.timestamp < ?
            GROUP BY p.id
            ORDER BY total_estimated DESC
            """
        let args: StatementArguments = [since, until]
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.compactMap { row -> ProjectSpend? in
                let pid: String? = row["project_id"]
                let pname: String? = row["project_name"]
                return ProjectSpend(
                    projectID: pid,
                    projectName: pname,
                    totalEstimated: (row["total_estimated"] as? Double) ?? 0,
                    generationCount: (row["generation_count"] as? Int) ?? 0
                )
            }
        }
    }

    public func fetchTopAssetsBySpend(
        limit: Int,
        since: String,
        until: String
    ) async throws -> [(Asset, Double)] {
        let sql = """
            SELECT
                a.*,
                COALESCE(SUM(sl.estimated_cost), 0) AS total_cost
            FROM spend_log sl
            JOIN assets a ON a.id = sl.asset_id
            WHERE sl.timestamp >= ? AND sl.timestamp < ?
            GROUP BY a.id
            ORDER BY total_cost DESC
            LIMIT ?
            """
        var mutableArgs: StatementArguments = [since, until]
        mutableArgs += [limit]
        let args = mutableArgs
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.compactMap { row -> (Asset, Double)? in
                guard let asset = try? Asset(row: row) else { return nil }
                let cost = (row["total_cost"] as? Double) ?? 0
                return (asset, cost)
            }
        }
    }

    public func fetchRecentSpendLog(limit: Int) async throws -> [SpendLog] {
        var args: StatementArguments = []
        args += [limit]
        return try await read { db in
            try SpendLog
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}
