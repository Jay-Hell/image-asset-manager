import Foundation

/// Input to `PromptFlattener` — either a plain text prompt or a structured dict.
///
/// Neither Imagen 4 nor Gemini 2.5 Flash Image has a native JSON prompt field;
/// both accept a single prompt string. We accept JSON because it's easier for
/// an LLM caller to compose reliably, then flatten to prose that the image
/// models actually prefer.
public enum PromptInput: @unchecked Sendable {
    case text(String)
    case structured([String: Any])
}

public enum PromptFlattener {

    /// Keys that appear in practitioner JSON schemas but mean nothing to the
    /// image model (they're generation-engine parameters, not prompt content).
    /// Dropped entirely during flattening.
    private static let ignoredKeys: Set<String> = [
        "seed", "steps", "sampler", "cfg_scale", "guidance_scale",
        "num_inference_steps", "scheduler", "model", "negative",
    ]

    /// Canonical Subject-Context-Style order. Known keys are emitted in this
    /// order for readability; unknown keys fall through to generic flattening
    /// appended afterwards.
    private static let canonicalOrder: [String] = [
        "subject", "context", "action", "setting",
        "style", "composition", "lighting", "mood", "camera",
        "color_palette", "palette", "details", "extra",
    ]

    public static func flatten(_ input: PromptInput) -> String {
        switch input {
        case .text(let prompt):
            return prompt

        case .structured(let dict):
            return flattenDict(dict, rootLevel: true)
        }
    }

    // MARK: - Private

    private static func flattenDict(_ dict: [String: Any], rootLevel: Bool) -> String {
        var out: [String] = []

        // Canonical keys first, in order.
        for key in canonicalOrder where dict[key] != nil {
            if let rendered = renderPair(key: key, value: dict[key]!) {
                out.append(rendered)
            }
        }

        // Everything else, stable order by key name.
        let canonicalSet = Set(canonicalOrder)
        let remaining = dict.keys
            .filter { !canonicalSet.contains($0) && !ignoredKeys.contains($0) }
            .sorted()
        for key in remaining {
            if let rendered = renderPair(key: key, value: dict[key]!) {
                out.append(rendered)
            }
        }

        return out.joined(separator: rootLevel ? ". " : ", ")
    }

    /// Render a single key/value as "Key: value" or similar, recursing into
    /// nested structures. Returns nil if the value is empty or uninformative.
    private static func renderPair(key: String, value: Any) -> String? {
        let label = humanLabel(for: key)
        guard let rendered = renderValue(value) else { return nil }
        // For top-level freeform collections like `extra`, emit as bare text
        // rather than "Extra: a, b, c" — reads more naturally.
        if key == "extra", value is [Any] {
            return rendered
        }
        return "\(label): \(rendered)"
    }

    private static func renderValue(_ value: Any) -> String? {
        switch value {
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed

        case let n as NSNumber:
            return n.stringValue

        case let arr as [Any]:
            let pieces = arr.compactMap { renderValue($0) }
            return pieces.isEmpty ? nil : pieces.joined(separator: ", ")

        case let d as [String: Any]:
            let inner = flattenDict(d, rootLevel: false)
            return inner.isEmpty ? nil : inner

        case is NSNull:
            return nil

        default:
            let desc = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return desc.isEmpty ? nil : desc
        }
    }

    private static func humanLabel(for key: String) -> String {
        switch key {
        case "color_palette", "palette": return "Palette"
        case "camera":                    return "Camera"
        case "composition":               return "Composition"
        case "lighting":                  return "Lighting"
        case "mood":                      return "Mood"
        case "style":                     return "Style"
        case "subject":                   return "Subject"
        case "context":                   return "Context"
        case "setting":                   return "Setting"
        case "action":                    return "Action"
        case "details":                   return "Details"
        default:
            // snake_case or camelCase → Title Case
            let withSpaces = key
                .replacingOccurrences(of: "_", with: " ")
                .reduce(into: "") { acc, ch in
                    if ch.isUppercase, let last = acc.last, !last.isWhitespace {
                        acc.append(" ")
                    }
                    acc.append(ch)
                }
            return withSpaces.prefix(1).uppercased() + withSpaces.dropFirst()
        }
    }
}
