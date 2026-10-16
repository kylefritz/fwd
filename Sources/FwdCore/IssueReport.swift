import Foundation

/// Turning a bug report or feature request into a prefilled GitHub issue,
/// with an optional slice of the log. Issues are public, so the log is
/// redacted, and the person sees exactly what will be shared first.
public enum IssueReport {
    public enum Kind: String, CaseIterable, Sendable {
        case bug, feature
        var template: String { "\(rawValue).yml" }
    }

    /// How far back the log goes, as offered in the window.
    public static let spans: [(label: String, seconds: TimeInterval?)] = [
        ("No log", nil), ("Last 15 minutes", 900), ("Last hour", 3600),
        ("Last 24 hours", 86_400), ("Last 7 days", 604_800),
    ]

    /// GitHub turns down very long URLs, so a log only goes in the issue
    /// itself when the whole link stays under this.
    static let maxURLLength = 7500

    // MARK: The log

    /// The log and the file it rolled over into, oldest first.
    public static func readLog(_ file: URL) -> String {
        let rolled = (try? String(contentsOf: file.appendingPathExtension("1"), encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return rolled + current
    }

    /// The lines written at or after `since`. Every line starts with its
    /// timestamp; one that doesn't belongs with the line before it.
    public static func excerpt(_ log: String, since: Date) -> String {
        let parse = ISO8601DateFormatter()
        parse.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var keeping = false
        var kept: [Substring] = []
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            if let space = line.firstIndex(of: " "), let date = parse.date(from: String(line[..<space])) {
                keeping = date >= since
            }
            if keeping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Removes what shouldn't be public: URL queries (sign-in tokens live
    /// there), `key=value` secrets, IP addresses, and the home folder and
    /// user name. With `hideHosts`, ssh host aliases become `host1`, `host2`
    /// and so on, and any other domain name becomes `[hostname]`.
    public static func redact(_ text: String, hosts: [String], hideHosts: Bool, home: String, user: String) -> String {
        var out = text
        func replace(_ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        replace(#"(https?://[^\s?]+)\?\S*"#, "$1?[redacted]")
        replace(#"\b(token|secret|password|passwd|apikey|api_key|key|auth|code)=[^\s&]+"#, "$1=[redacted]", .caseInsensitive)
        replace(#"\b(Bearer|Basic)\s+\S+"#, "$1 [redacted]", .caseInsensitive)
        replace(#"\b\d{1,3}(\.\d{1,3}){3}\b"#, "[ip]")
        if !home.isEmpty { out = out.replacingOccurrences(of: home, with: "~") }

        guard hideHosts else { return out }
        // Longest first, so `dev` can't eat part of `devbox`.
        let aliases = Array(Set(hosts.filter { !$0.isEmpty })).sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        // Numbered by first appearance, so the same host always reads the same.
        let order = aliases.sorted { (out.range(of: $0)?.lowerBound ?? out.endIndex) < (out.range(of: $1)?.lowerBound ?? out.endIndex) }
        for alias in aliases {
            let n = (order.firstIndex(of: alias) ?? 0) + 1
            replace(#"(?<![\w.-])"# + NSRegularExpression.escapedPattern(for: alias) + #"(?![\w-])"#, "host\(n)")
        }
        replace(#"\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\b"#, "[hostname]", .caseInsensitive)
        if !user.isEmpty {
            replace(#"(?<![\w.-])"# + NSRegularExpression.escapedPattern(for: user) + #"(?![\w-])"#, "user")
        }
        return out
    }

    // MARK: The issue

    public struct Issue: Sendable {
        public let url: URL
        /// False when the log was too long for the link; the person then
        /// adds it to the issue themselves.
        public let logInline: Bool
    }

    /// A link to GitHub's new-issue form for `kind`, with its fields filled in.
    public static func issue(kind: Kind, title: String, version: String, macOS: String, log: String?) -> Issue {
        func link(_ fields: [(String, String)]) -> URL {
            var parts = URLComponents(string: "https://github.com/\(Paths.repository)/issues/new")!
            parts.queryItems = [URLQueryItem(name: "template", value: kind.template)]
                + fields.filter { !$0.1.isEmpty }.map { URLQueryItem(name: $0.0, value: $0.1) }
            // `+` means a space in a query; spell it out so `3000 -> 4000` survives.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return parts.url!
        }
        let base: [(String, String)] = [("title", title), ("version", version), ("macos", macOS)]
        guard let log, !log.isEmpty else { return Issue(url: link(base), logInline: true) }
        let withLog = link(base + [("log", log)])
        if withLog.absoluteString.count <= maxURLLength { return Issue(url: withLog, logInline: true) }
        let note = "The log was too long to include here. Drag in the file fwd showed in Finder, or paste it: it's on your clipboard."
        return Issue(url: link(base + [("log", note)]), logInline: false)
    }
}
