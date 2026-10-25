import Foundation

/// Client, project and tag-rename names are unique ignoring case in every script: "Écran" and
/// "écran" clash. SQLite's `LOWER` folds A–Z only, so the comparison is made here, in Swift.
/// Case only: "Ecran" and "Écran" are two names.
enum NameMatch {
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
    }

    static func same(_ a: String, _ b: String) -> Bool { key(a) == key(b) }
}
