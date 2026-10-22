import Testing
import Foundation
@testable import ImageAssetManagerCore

// Pass D fix round. Every paid call is recorded exactly once: a `refused_spend` row ("not kept") the
// moment the image exists, swapped for the asset's `spend_log` row on Keep. Panel and MCP alike.

private struct Rows {
    let refused: Int
    let spend: Int
    let assets: Int
    let reasons: [String]
}

private func rows(_ db: AppDatabase) async throws -> Rows {
    try await db.read { db in
        Rows(
            refused: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM refused_spend") ?? 0,
            spend: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spend_log") ?? 0,
            assets: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") ?? 0,
            reasons: try String.fetchAll(db, sql: "SELECT reason FROM refused_spend ORDER BY timestamp"))
    }
}

/// The panel's Generate step through Core, on the providers the install can use.
private func panelRun(_ rig: ToolsRig, tier: String = "fast") async throws -> PanelGeneration {
    try await PanelGeneration.run(
        selection: .tier(tier), referenceCount: 0, aspectRatio: "1:1", prompt: "a viaduct", negativePrompt: nil,
        shape: .square, width: 1024, height: 1024, references: [], providers: rig.usable(),
        database: rig.db, libraryURL: rig.dir, catalogue: { rig.store.snapshot() }, live: rig.live)
}

private func service(_ rig: ToolsRig, _ run: PanelGeneration) throws -> GenerationService {
    try PanelGeneration.service(for: run.prepared, providers: rig.usable(), database: rig.db, libraryURL: rig.dir, live: rig.live)
}

@Suite("every paid call is recorded exactly once")
struct PaidCallRecordedOnceTests {

    @Test func aPaidImageIsOneNotKeptRowTheMomentItExistsAndDiscardingLeavesIt() async throws {
        let rig = try await ToolsRig.make()
        let run = try await panelRun(rig)
        // Generated and held, nothing kept yet: the charge is already recorded, once.
        let held = try await rows(rig.db)
        #expect(held.refused == 1 && held.spend == 0 && held.assets == 0)
        #expect(held.reasons == ["not kept"])
        // Discard writes nothing, so the spend still counts (0.0336 USD x 0.79 = £0.026544).
        _ = run
        let summary = try await rig.db.fetchSpendSummary(since: "2000-01-01", until: "2100-01-01")
        #expect(summary.generationCount == 1)
        #expect(abs(summary.totalEstimated - 0.026544) < 1e-9)
    }

    @Test func aSecondGenerateWithoutKeepingTheFirstLeavesBothCharged() async throws {
        let rig = try await ToolsRig.make()
        _ = try await panelRun(rig)
        _ = try await panelRun(rig)           // replace-by-Generate (or quitting between the two)
        let held = try await rows(rig.db)
        #expect(held.refused == 2 && held.spend == 0 && held.assets == 0)
    }

    @Test func keepSwapsTheNotKeptRowForOneSpendRowAndTheAssetInOneStep() async throws {
        let rig = try await ToolsRig.make()
        let run = try await panelRun(rig)
        let request = run.prepared.request(prompt: "a viaduct", aspectRatio: .square, width: 1024, height: 1024)
        let outcome = try await service(rig, run).record(run.generated, for: request)
        let kept = try await rows(rig.db)
        #expect(kept.refused == 0 && kept.spend == 1 && kept.assets == 1)
        #expect(outcome.assetID == run.generated.chargeID)
        let summary = try await rig.db.fetchSpendSummary(since: "2000-01-01", until: "2100-01-01")
        #expect(summary.generationCount == 1)                // counted once, not twice
    }

    @Test func aSecondKeepWritesNothingNew() async throws {
        let rig = try await ToolsRig.make()
        let run = try await panelRun(rig)
        let request = run.prepared.request(prompt: "a viaduct", aspectRatio: .square, width: 1024, height: 1024)
        let first = try await service(rig, run).record(run.generated, for: request)
        let second = try await service(rig, run).record(run.generated, for: request)
        let kept = try await rows(rig.db)
        #expect(kept.refused == 0 && kept.spend == 1 && kept.assets == 1)
        #expect(second.assetID == first.assetID)
        let files = try FileManager.default.contentsOfDirectory(atPath: rig.dir.appending(path: "assets").path)
        #expect(files.count == 1)
    }

    @Test func aKeepThatFailsLeavesTheChargeAndTheNextKeepStillWritesOneRow() async throws {
        let rig = try await ToolsRig.make()
        let run = try await panelRun(rig)
        // The first Keep names a project that does not exist: the asset insert breaks its foreign key
        // inside the transaction, so nothing is kept and the "not kept" row survives.
        let bad = run.prepared.request(
            prompt: "a viaduct", aspectRatio: .square, width: 1024, height: 1024, projectIDs: ["no-such-project"])
        await #expect(throws: (any Error).self) {
            try await service(rig, run).record(run.generated, for: bad)
        }
        let failed = try await rows(rig.db)
        #expect(failed.refused == 1 && failed.spend == 0 && failed.assets == 0)
        #expect(failed.reasons == ["not kept"])
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: rig.dir.appending(path: "assets").path)) ?? []
        #expect(leftovers.isEmpty)                           // the stored file did not outlive the rollback

        // The pair: the same answer kept properly afterwards is exactly one spend row and one asset.
        let good = run.prepared.request(prompt: "a viaduct", aspectRatio: .square, width: 1024, height: 1024)
        _ = try await service(rig, run).record(run.generated, for: good)
        let kept = try await rows(rig.db)
        #expect(kept.refused == 0 && kept.spend == 1 && kept.assets == 1)
    }

    @Test func aRefusedImageIsOneRowWhichSaysWhyEvenIfKeptTwice() async throws {
        // Declared SVG, bytes are a PNG: the library refuses it, and the provider has already charged.
        let rig = try await ToolsRig.make(googleKey: false, openRouter: { _ in (200, okBody(mime: "image/svg+xml"), [:]) })
        let run = try await panelRun(rig)
        let request = run.prepared.request(prompt: "a viaduct", aspectRatio: .square, width: 1024, height: 1024)
        for _ in 0..<2 {
            await #expect(throws: GenerationServiceError.self) {
                try await service(rig, run).record(run.generated, for: request)
            }
        }
        let after = try await rows(rig.db)
        #expect(after.refused == 1 && after.spend == 0 && after.assets == 0)
        #expect(after.reasons.first != "not kept")
    }

    @Test func theMCPRecordsAKeptImageOnceAndARefusedOneOnce() async throws {
        let rig = try await ToolsRig.make()
        _ = try await rig.call("generate", ["prompt": "p", "count": 2])
        let kept = try await rows(rig.db)
        #expect(kept.refused == 0 && kept.spend == 2 && kept.assets == 2)
        // The pair: a refused answer is one charge row, not two.
        let refusing = try await ToolsRig.make(googleKey: false, openRouter: { _ in (200, okBody(mime: "image/svg+xml"), [:]) })
        do {
            _ = try await refusing.call("generate", ["prompt": "p"])
            Issue.record("a contradicted label should be refused")
        } catch {}
        let after = try await rows(refusing.db)
        #expect(after.refused == 1 && after.spend == 0 && after.assets == 0)
    }

    // MARK: - A paid answer with no image

    @Test func aTwoHundredWithACostAndNoImageIsRecordedAtItsActualCostAndSaysSo() async throws {
        let empty = Data(#"{"data":[],"usage":{"cost":0.5}}"#.utf8)
        let rig = try await ToolsRig.make(googleKey: false, openRouter: { _ in (200, empty, [:]) })
        do {
            _ = try await rig.call("generate", ["prompt": "p", "quality": "fast"])
            Issue.record("no image should be reported")
        } catch {
            #expect(error.localizedDescription.contains("no image returned"))
            #expect(error.localizedDescription.contains("0.3950"))        // $0.50 x 0.79, the actual cost
        }
        let after = try await rows(rig.db)
        #expect(after.refused == 1 && after.spend == 0 && after.assets == 0)
        #expect(after.reasons == ["no image returned"])
        let summary = try await rig.db.fetchSpendSummary(since: "2000-01-01", until: "2100-01-01")
        #expect(abs(summary.totalActual - 0.395) < 1e-9)
    }

    @Test func aTwoHundredWithNoImageAndNoCostRecordsNothing() async throws {
        let empty = Data(#"{"data":[]}"#.utf8)
        let rig = try await ToolsRig.make(googleKey: false, openRouter: { _ in (200, empty, [:]) })
        do {
            _ = try await rig.call("generate", ["prompt": "p", "quality": "fast"])
            Issue.record("an empty answer should be reported")
        } catch {
            #expect(!error.localizedDescription.contains("no image returned"))
        }
        let after = try await rows(rig.db)
        #expect(after.refused == 0 && after.spend == 0)
    }
}
