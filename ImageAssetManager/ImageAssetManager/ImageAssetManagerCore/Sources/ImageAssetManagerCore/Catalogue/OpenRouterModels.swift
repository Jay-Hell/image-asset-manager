import Foundation

/// One entry of OpenRouter's public image-model list (`GET /api/v1/images/models`): which
/// parameters the model takes and with what values. This is the third source of model
/// knowledge in spec v0.3 §5.2; nobody edits it.
public struct OpenRouterModel: Sendable, Equatable {
    public enum Parameter: Sendable, Equatable {
        case enumeration([String])
        case range(min: Int, max: Int)
        case flag(Bool)
    }

    public let id: String
    public let name: String
    public let inputModalities: [String]
    public let outputModalities: [String]
    public let parameters: [String: Parameter]

    public func values(of name: String) -> [String] {
        if case .enumeration(let v)? = parameters[name] { return v }
        return []
    }

    public func maxOf(_ name: String) -> Int? {
        if case .range(_, let max)? = parameters[name] { return max }
        return nil
    }

    public var lists: Set<String> { Set(parameters.keys) }

    /// The model as the resolver sees a catalogue entry. Capabilities, ratios, sizes and
    /// formats come from the live record; price, display name and body defaults come from a
    /// catalogue entry for the same model if there is one.
    func asCatalogueModel(overlay: Catalogue.Model? = nil) -> Catalogue.Model {
        var caps: Set<String> = overlay?.extraCapabilities ?? []
        if case .flag(true)? = parameters["seed"] { caps.insert(Catalogue.Capability.seed.rawValue) }
        if values(of: "background").contains("transparent") {
            caps.insert(Catalogue.Capability.transparentBackground.rawValue)
        }
        var model = Catalogue.Model(
            id: id,
            api: "openrouter.images",
            displayName: overlay?.displayName ?? name,
            aspectRatios: values(of: "aspect_ratio"),
            maxReferenceImages: maxOf("input_references") ?? 0,
            imageSizes: values(of: "resolution"),
            extraCapabilities: caps,
            usdEstimate: overlay?.usdEstimate,
            usdByImageSize: overlay?.usdByImageSize ?? [:],
            body: overlay?.body ?? [:],
            minBuild: nil
        )
        model.outputFormats = values(of: "output_format")
        return model
    }
}

/// Where a per-image price came from. Recorded on every `Resolution`.
public enum EstimateSource: String, Sendable, Equatable {
    /// The catalogue's route or model entry.
    case catalogue
    /// OpenRouter's `/endpoints` record for the model, priced per image.
    case endpointPricing = "endpoint_pricing"
    /// The first real `usage.cost` seen for the model.
    case observedCost = "observed_cost"
    /// Nothing known: the compiled $0.20 gate.
    case unknownDefault = "unknown_default"
}

public struct OpenRouterPrice: Sendable, Equatable, Codable {
    public let usdPerImage: Decimal
    public let source: String   // EstimateSource raw value; kept a string so the cache file stays plain
}

/// A snapshot of the live list and of the prices learnt for it.
public struct OpenRouterModels: Sendable, Equatable {
    public let models: [OpenRouterModel]
    public let prices: [String: OpenRouterPrice]

    public static let empty = OpenRouterModels(models: [], prices: [:])

    public init(models: [OpenRouterModel], prices: [String: OpenRouterPrice] = [:]) {
        self.models = models
        self.prices = prices
    }

    public var isEmpty: Bool { models.isEmpty }
    public func model(_ id: String) -> OpenRouterModel? { models.first { $0.id == id } }

    public enum ParseError: Error, Equatable, LocalizedError {
        case tooLarge(Int)
        case notAModelList
        case noModels

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let n):  return "OpenRouter model list is \(n) bytes, over the \(OpenRouterModels.maxBytes)-byte limit."
            case .notAModelList:    return "OpenRouter model list is not the expected shape."
            case .noModels:         return "OpenRouter model list had no usable image model."
            }
        }
    }

    public static let maxBytes = 4 * 1024 * 1024

    /// Decode the real listing (T20). Entries that are not image generators, or whose ID
    /// would not pass the same check the catalogue applies, are dropped; a list with none left
    /// throws, so an empty or hostile answer can never replace a good cache.
    public static func parse(_ data: Data, prices: [String: OpenRouterPrice] = [:]) throws -> OpenRouterModels {
        guard data.count <= maxBytes else { throw ParseError.tooLarge(data.count) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { throw ParseError.notAModelList }
        var out: [OpenRouterModel] = []
        var seen = Set<String>()
        for item in items {
            guard let id = item["id"] as? String, Catalogue.isValidModelID(id, allowSlash: true),
                  !seen.contains(id) else { continue }
            let arch = item["architecture"] as? [String: Any]
            let outputs = (arch?["output_modalities"] as? [String]) ?? []
            guard outputs.contains("image") else { continue }
            var params: [String: OpenRouterModel.Parameter] = [:]
            for (key, any) in (item["supported_parameters"] as? [String: Any]) ?? [:] {
                guard let spec = any as? [String: Any], let type = spec["type"] as? String else { continue }
                switch type {
                case "enum":
                    if let values = spec["values"] as? [String] { params[key] = .enumeration(values) }
                case "range":
                    if let lo = (spec["min"] as? NSNumber)?.intValue, let hi = (spec["max"] as? NSNumber)?.intValue {
                        params[key] = .range(min: lo, max: hi)
                    }
                case "boolean":
                    params[key] = .flag(true)
                default:
                    continue
                }
            }
            seen.insert(id)
            out.append(OpenRouterModel(
                id: id,
                name: (item["name"] as? String) ?? id,
                inputModalities: (arch?["input_modalities"] as? [String]) ?? [],
                outputModalities: outputs,
                parameters: params
            ))
        }
        guard !out.isEmpty else { throw ParseError.noModels }
        return OpenRouterModels(models: out, prices: prices)
    }

    /// A per-image USD price from a model's `/endpoints` record, where the record prices by
    /// the image. Token-priced records (the Gemini models) give nothing: tokens per image are
    /// not in the record. Several endpoints: the dearest, because this feeds a spending gate.
    public static func perImageUSD(fromEndpoints data: Data) -> Decimal? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let endpoints = root["endpoints"] as? [[String: Any]] else { return nil }
        var best: Decimal?
        for endpoint in endpoints {
            for line in (endpoint["pricing"] as? [[String: Any]]) ?? [] {
                guard (line["billable"] as? String) == "output_image", (line["unit"] as? String) == "image",
                      let n = line["cost_usd"] as? NSNumber, n.doubleValue > 0 else { continue }
                let d = Catalogue.decimal(n.doubleValue)
                if best == nil || d > best! { best = d }
            }
        }
        return best
    }
}
