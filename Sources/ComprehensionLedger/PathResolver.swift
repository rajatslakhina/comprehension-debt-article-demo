/// Turns a repository-relative path into a canonical form, so that
/// `Sources/Settings/../Payments/Refund.swift` is metered as Payments.
enum PathResolver {
    /// Returns the canonical path, or `nil` for a path that is absolute,
    /// empty, contains a backslash, or climbs above the repository root.
    static func canonical(_ raw: String) -> String? {
        let trimmed = raw.trimmingWhitespace
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\") else { return nil }
        var parts: [Substring] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default:
                parts.append(component)
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// True when `path` is inside the directory `prefix`. Both must be
    /// canonical. `Sources/PaymentsUI/x.swift` is not inside `Sources/Payments`.
    static func path(_ path: String, isInside prefix: String) -> Bool {
        path.hasPrefix(prefix + "/")
    }
}

extension String {
    var trimmingWhitespace: String {
        var scalars = Substring(self)
        while let first = scalars.first, first.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }

    var isBlank: Bool { trimmingWhitespace.isEmpty }
}
