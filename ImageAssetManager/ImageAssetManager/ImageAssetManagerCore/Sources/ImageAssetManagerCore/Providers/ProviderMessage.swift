import Foundation

/// The human-readable part of a provider's error body. Anthropic answers
/// `{"type":"error","error":{"type":"…","message":"…"}}`, Google and OpenRouter
/// `{"error":{"message":"…"}}`; the user should read the message, not the JSON around it.
public enum ProviderMessage {

    /// Long enough for any real message, short enough that an HTML error page cannot flood the panel.
    public static let maxLength = 2000

    /// The message in `data`, or its text if it is not JSON, or nil if there is nothing to show.
    /// Anything in `secrets` is replaced, so a provider that echoes a key back cannot put it on screen.
    public static func text(from data: Data, redacting secrets: [String] = []) -> String? {
        var found: String?
        if let object = try? JSONSerialization.jsonObject(with: data) { found = message(in: object) }
        if found == nil {
            found = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard var text = found, !text.isEmpty else { return nil }
        for secret in secrets where secret.count >= 8 {
            text = text.replacingOccurrences(of: secret, with: "[key]")
        }
        // A key echoed in a URL query (`?key=…`), whatever it is: Google takes its key there.
        text = text.replacingOccurrences(
            of: #"([?&]key=)[^&\s"'<>]+"#, with: "$1[key]", options: .regularExpression)
        return text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }

    private static func message(in object: Any) -> String? {
        if let list = object as? [Any] { return list.lazy.compactMap { message(in: $0) }.first }
        guard let dict = object as? [String: Any] else { return nil }
        if let error = dict["error"] as? [String: Any], let m = error["message"] as? String, !m.isEmpty { return m }
        if let error = dict["error"] as? String, !error.isEmpty { return error }
        if let m = dict["message"] as? String, !m.isEmpty { return m }
        return nil
    }
}
