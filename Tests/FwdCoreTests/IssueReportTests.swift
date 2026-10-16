import Foundation
import Testing
@testable import FwdCore

@Suite struct IssueReportTests {
    let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00-04:00")!

    let log = """
        2026-10-14T09:00:00.000-04:00 fwd started
        2026-10-15T10:42:30.038-04:00 [mbar] ssh: A browser window should have opened at the following URL:
        2026-10-15T10:42:30.038-04:00 [mbar] ssh: https://ssh.thepuff.co/cdn-cgi/access/cli?aud=73a7&token=OU1PwIeN%3D
        2026-10-15T11:30:00.000-04:00 [vdesk] ssh: ssh: connect to host kfritz.vdesk.cloud.aurora.tech port 22: Operation timed out
        2026-10-15T11:31:00.000-04:00 [vdesk] connect failed; retrying in 2s
        2026-10-15T11:45:00.000-04:00 opened /Users/kfritz/.ssh/config for kfritz from 10.20.30.40
        """

    @Test func excerptKeepsOnlyTheChosenSpan() {
        let lastHour = IssueReport.excerpt(log, since: now.addingTimeInterval(-3600))
        #expect(lastHour.split(separator: "\n").count == 3)
        #expect(lastHour.hasPrefix("2026-10-15T11:30"))
        #expect(IssueReport.excerpt(log, since: now.addingTimeInterval(-86_400)).split(separator: "\n").count == 5)
    }

    @Test func secretsAreAlwaysRemoved() {
        let text = IssueReport.redact(log, hosts: [], hideHosts: false, home: "/Users/kfritz", user: "kfritz")
        #expect(!text.contains("OU1PwIeN"), "sign-in tokens")
        #expect(!text.contains("aud=73a7"))
        #expect(text.contains("https://ssh.thepuff.co/cdn-cgi/access/cli?[redacted]"))
        #expect(!text.contains("/Users/kfritz"))
        #expect(text.contains("~/.ssh/config"))
        #expect(!text.contains("10.20.30.40"))
        #expect(text.contains("[mbar]"), "host names stay unless asked")
    }

    @Test func hostNamesCanBeReplaced() {
        let text = IssueReport.redact(log, hosts: ["mbar", "vdesk"], hideHosts: true, home: "/Users/kfritz", user: "kfritz")
        #expect(!text.contains("mbar"))
        #expect(!text.contains("vdesk"))
        #expect(!text.contains("thepuff"))
        #expect(!text.contains("aurora"))
        #expect(!text.contains("kfritz"))
        #expect(text.contains("[host1] ssh:"))
        #expect(text.contains("[host2] connect failed"))
        // The same name always gets the same stand-in.
        #expect(text.components(separatedBy: "[host1]").count == 3)
    }

    @Test func aShortLogGoesInTheIssueAndALongOneDoesNot() throws {
        let short = IssueReport.issue(kind: .bug, title: "Retries forever", version: "0.1.0", macOS: "26.1.0", log: "a line")
        #expect(short.logInline)
        let url = short.url.absoluteString
        #expect(url.hasPrefix("https://github.com/kylefritz/fwd/issues/new?"))
        let items = try #require(URLComponents(url: short.url, resolvingAgainstBaseURL: false)?.queryItems)
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(fields["template"] == "bug.yml")
        #expect(fields["title"] == "Retries forever")
        #expect(fields["version"] == "0.1.0")
        #expect(fields["macos"] == "26.1.0")
        #expect(fields["log"] == "a line")

        let long = IssueReport.issue(kind: .bug, title: "", version: "0.1.0", macOS: "26.1.0",
                                     log: String(repeating: "2026-10-15T11:30:00.000-04:00 [host1] retrying\n", count: 400))
        #expect(!long.logInline)
        #expect(long.url.absoluteString.count < 8000)

        let feature = IssueReport.issue(kind: .feature, title: "Groups", version: "0.1.0", macOS: "26.1.0", log: nil)
        #expect(feature.url.absoluteString.contains("template=feature.yml"))
        #expect(!feature.url.absoluteString.contains("log="))
    }
}
