#if os(macOS)
import Foundation
import ImageAssetManagerCore

/// Handler for the MCP `generate_image` tool. Parses tool arguments, applies
/// the cost gate, resolves references, auto-routes to the ref-capable model
/// when necessary, and drives `GenerationService` once per image.
extension MCPServer {

    func handleGenerateImage(args: [String: Any]) async throws -> Any {
        // --- 1. Prompt ---------------------------------------------------
        let promptInput: PromptInput
        if let text = args["prompt"] as? String {
            promptInput = .text(text)
        } else if let dict = args["prompt"] as? [String: Any] {
            promptInput = .structured(dict)
        } else {
            throw MCPGenerateError.invalidParam("prompt must be a string or JSON object")
        }
        let basePrompt = PromptFlattener.flatten(promptInput)
        guard !basePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPGenerateError.invalidParam("prompt is empty after flattening")
        }
        let negativePrompt = (args["negative_prompt"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        // --- 2. Quality / count / aspect ratio --------------------------
        let qualityRaw = (args["quality"] as? String)?.lowercased() ?? "auto"
        let count = max(1, (args["count"] as? Int) ?? 1)
        let aspectRaw = (args["aspect_ratio"] as? String)?.lowercased() ?? "square"
        let aspect: AspectRatio = {
            switch aspectRaw {
            case "landscape": return .landscape
            case "portrait":  return .portrait
            default:          return .square
            }
        }()
        let (width, height) = resolveDimensions(for: aspect)

        // --- 3. Budget defaults -----------------------------------------
        let budget = GenerationPolicy.BudgetLimits(
            maxImages: (args["max_images"] as? Int) ?? GenerationPolicy.BudgetLimits.defaults.maxImages,
            maxCostGBP: decimalArg(args["max_cost_gbp"]) ?? GenerationPolicy.BudgetLimits.defaults.maxCostGBP
        )

        // --- 4. Project / collection resolution -------------------------
        // Accept either a singular "project" string (primary) or a "projects" array
        // (first is primary). A mix is allowed — singular acts as the primary when
        // "projects" is absent.
        var resolvedProjects: [Project] = []
        if let raw = args["project"] as? String, !raw.isEmpty {
            guard let p = try await database.findProject(idOrName: raw) else {
                throw MCPGenerateError.notFound("project '\(raw)'")
            }
            resolvedProjects.append(p)
        }
        if let rawList = args["projects"] as? [String] {
            for raw in rawList where !raw.isEmpty {
                guard let p = try await database.findProject(idOrName: raw) else {
                    throw MCPGenerateError.notFound("project '\(raw)'")
                }
                if !resolvedProjects.contains(where: { $0.id == p.id }) {
                    resolvedProjects.append(p)
                }
            }
        }
        let project: Project? = resolvedProjects.first

        let collection: ImageCollection? = try await {
            guard let raw = args["collection"] as? String, !raw.isEmpty else { return nil }
            guard let c = try await database.findCollection(idOrName: raw, projectID: project?.id) else {
                throw MCPGenerateError.notFound("collection '\(raw)'")
            }
            return c
        }()

        // --- 5. References ----------------------------------------------
        var notes: [String] = []
        let references = try await resolveReferences(
            args: args,
            project: project,
            notes: &notes
        )

        // --- 6. Effective model (quality → model ID) --------------------
        let provider = NanaBananaProvider()
        let route: GenerationPolicy.ModelRoute
        do {
            route = try GenerationPolicy.chooseModel(quality: qualityRaw, hasReferences: !references.isEmpty)
        } catch GenerationPolicy.QualityError.unknown(let q) {
            throw MCPGenerateError.invalidParam("unknown quality '\(q)' (expected fast|standard|pro|with_references|auto)")
        }
        if route.autoRouted {
            notes.append("Auto-routed to with_references because references are attached; \(qualityRaw) can't use them on this API")
        }
        guard let effectiveModel = provider.availableModels.first(where: { $0.id == route.modelID }) else {
            throw MCPGenerateError.invalidParam("internal: model '\(route.modelID)' not found in provider catalogue")
        }

        // --- 7. Cost gate -----------------------------------------------
        let unitCost = effectiveModel.costPerImage
        let subtotal: Decimal
        do {
            subtotal = try GenerationPolicy.checkBudget(count: count, unitCost: unitCost, limits: budget)
        } catch GenerationPolicy.BudgetViolation.tooManyImages(let c, let m) {
            throw MCPGenerateError.limitExceeded(
                "count \(c) exceeds max_images \(m)",
                details: ["count": c, "max_images": m]
            )
        } catch GenerationPolicy.BudgetViolation.tooCostly(let sub, let m) {
            throw MCPGenerateError.limitExceeded(
                "projected spend \(format(sub)) exceeds max_cost_gbp \(format(m))",
                details: [
                    "count": count,
                    "unit_cost_gbp": doubleValue(unitCost),
                    "subtotal_gbp": doubleValue(sub),
                    "max_cost_gbp": doubleValue(m),
                ]
            )
        }

        // --- 8. Generate (one image per loop) ---------------------------
        let tags = (args["tags"] as? [String]) ?? []
        let variantFamily = args["variant_family"] as? String

        let service = GenerationService(
            database: database,
            libraryURL: libraryURL,
            provider: provider
        )

        var outcomes: [[String: Any]] = []
        for _ in 0..<count {
            let request = GenerationService.Request(
                prompt: basePrompt,
                negativePrompt: negativePrompt,
                model: effectiveModel,
                aspectRatio: aspect,
                width: width,
                height: height,
                references: references,
                projectIDs: resolvedProjects.map(\.id),
                collectionID: collection?.id,
                tags: tags,
                variantFamilyName: variantFamily
            )
            let outcome = try await service.generate(request)
            outcomes.append([
                "asset_id": outcome.assetID,
                "file_path": outcome.fileURL.path(percentEncoded: false),
                "model_used": outcome.modelID,
                "estimated_cost_gbp": outcome.estimatedCost,
                "actual_cost_gbp": outcome.actualCost as Any? ?? NSNull(),
                "seed": outcome.seed as Any? ?? NSNull(),
            ])
        }

        return [
            "generated": outcomes,
            "total_cost_gbp": doubleValue(subtotal),
            "cost_breakdown": [
                "model": effectiveModel.id,
                "count": count,
                "unit_cost_gbp": doubleValue(unitCost),
                "subtotal_gbp": doubleValue(subtotal),
            ] as [String: Any],
            "notes": notes,
        ] as [String: Any]
    }

    // MARK: - Reference resolution

    private func resolveReferences(
        args: [String: Any],
        project: Project?,
        notes: inout [String]
    ) async throws -> [GenerationReference] {
        var projectRefs: [GenerationReference] = []
        if let projectID = project?.id {
            let entries = try await database.fetchActiveReferenceEntries(projectID: projectID)
            for entry in entries {
                guard let asset = try await database.fetchAsset(id: entry.assetID) else { continue }
                let fileURL = libraryURL.appending(path: "assets").appending(path: asset.filename)
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                let role: ReferenceRole = entry.role == "style_anchor" ? .styleAnchor : .subjectAnchor
                projectRefs.append(GenerationReference(
                    input: ReferenceInput(
                        assetID: entry.assetID,
                        imageData: data,
                        role: role,
                        weight: Float(entry.weight)
                    ),
                    referenceSetID: entry.referenceSetID,
                    referenceEntryID: entry.id
                ))
            }
        }

        var explicitRefs: [GenerationReference] = []
        if let list = args["references"] as? [[String: Any]] {
            for item in list {
                guard let assetID = item["asset_id"] as? String else { continue }
                guard let asset = try await database.fetchAsset(id: assetID) else {
                    throw MCPGenerateError.notFound("asset '\(assetID)' (in references)")
                }
                let fileURL = libraryURL.appending(path: "assets").appending(path: asset.filename)
                guard let data = try? Data(contentsOf: fileURL) else {
                    throw MCPGenerateError.notFound("file on disk for asset '\(assetID)'")
                }
                let role: ReferenceRole
                switch (item["role"] as? String)?.lowercased() {
                case "style_anchor":   role = .styleAnchor
                case "subject_anchor": role = .subjectAnchor
                default:               role = .subjectAnchor
                }
                explicitRefs.append(GenerationReference(
                    input: ReferenceInput(assetID: assetID, imageData: data, role: role, weight: nil),
                    referenceSetID: nil,
                    referenceEntryID: nil
                ))
            }
        }

        let merged = GenerationPolicy.mergeReferences(project: projectRefs, explicit: explicitRefs)
        if merged.truncated {
            notes.append("Truncated to first 3 references (provider limit)")
        }
        return merged.references
    }

    // MARK: - Helpers

    private func resolveDimensions(for aspect: AspectRatio) -> (Int, Int) {
        switch aspect {
        case .square:    return (1024, 1024)
        case .landscape: return (1792, 1024)
        case .portrait:  return (1024, 1792)
        case .custom:    return (1024, 1024)
        }
    }

    private func decimalArg(_ any: Any?) -> Decimal? {
        switch any {
        case let d as Double:  return Decimal(d)
        case let i as Int:     return Decimal(i)
        case let n as NSNumber: return Decimal(n.doubleValue)
        case let s as String:  return Decimal(string: s)
        default: return nil
        }
    }

    private func doubleValue(_ d: Decimal) -> Double {
        Double(truncating: d as NSDecimalNumber)
    }

    private func format(_ d: Decimal) -> String {
        String(format: "£%.4f", doubleValue(d))
    }
}

enum MCPGenerateError: Error, LocalizedError {
    case invalidParam(String)
    case notFound(String)
    case limitExceeded(String, details: [String: Any])

    var errorDescription: String? {
        switch self {
        case .invalidParam(let msg):   return "Invalid parameter: \(msg)"
        case .notFound(let what):      return "Not found: \(what)"
        case .limitExceeded(let msg, _): return "Limit exceeded: \(msg)"
        }
    }
}
#endif
