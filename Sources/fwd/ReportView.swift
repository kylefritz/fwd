import AppKit
import FwdCore
import SwiftUI

/// Report a bug or request a feature: picks how much of the log to share,
/// shows exactly what will be shared after redaction, then opens a
/// prefilled issue on GitHub. Nothing is sent until it's submitted there.
struct ReportView: View {
    let app: AppDelegate
    @ObservedObject var model: AppModel
    let close: () -> Void

    @State var kind: IssueReport.Kind
    @State private var title = ""
    @State private var span: Int
    @State private var hideHosts = true
    @State private var preview = ""

    init(kind: IssueReport.Kind, app: AppDelegate, model: AppModel, close: @escaping () -> Void) {
        self.app = app
        self.model = model
        self.close = close
        _kind = State(initialValue: kind)
        _span = State(initialValue: Self.defaultSpan(kind))
    }

    /// A bug report starts with the last hour of log; a feature request with none.
    static func defaultSpan(_ kind: IssueReport.Kind) -> Int { kind == .bug ? 2 : 0 }

    private var includesLog: Bool { IssueReport.spans[span].seconds != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $kind) {
                Text("Bug report").tag(IssueReport.Kind.bug)
                Text("Feature request").tag(IssueReport.Kind.feature)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: kind) { _, new in span = Self.defaultSpan(new) }

            TextField(kind == .bug ? "What went wrong, in a few words" : "Your idea, in a few words", text: $title)
                .textFieldStyle(.roundedBorder)

            HStack {
                Picker("Log", selection: $span) {
                    ForEach(IssueReport.spans.indices, id: \.self) { Text(IssueReport.spans[$0].label).tag($0) }
                }
                .fixedSize()
                Toggle("Replace host names", isOn: $hideHosts)
                    .disabled(!includesLog)
                    .help("Shows your ssh hosts as host1, host2, … and other domain names as [hostname]")
            }

            if includesLog {
                ScrollView {
                    Text(preview.isEmpty ? "Nothing in the log for this period." : preview)
                        .font(.caption.monospaced())
                        .foregroundStyle(preview.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 180, maxHeight: 280)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                Text("\(preview.isEmpty ? 0 : preview.split(separator: "\n").count) lines. Sign-in tokens, passwords, IP addresses and your home folder are always removed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("This opens a public issue on github.com with this filled in. Nothing is sent until you submit it there.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Continue on GitHub", action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520)
        // Hosts load after launch, so a change to them redoes the preview too.
        .task(id: "\(span)-\(hideHosts)-\(model.cards.map(\.name))") { refreshPreview() }
    }

    private func refreshPreview() {
        guard let seconds = IssueReport.spans[span].seconds else {
            preview = ""
            return
        }
        let log = IssueReport.readLog(model.paths.logFile)
        let excerpt = IssueReport.excerpt(log, since: Date().addingTimeInterval(-seconds))
        preview = IssueReport.redact(excerpt, hosts: model.cards.map(\.name), hideHosts: hideHosts,
                                     home: NSHomeDirectory(), user: NSUserName())
    }

    private func submit() {
        let log = includesLog && !preview.isEmpty ? preview : nil
        let issue = IssueReport.issue(kind: kind, title: title, version: AppDelegate.version,
                                      macOS: Updater.systemVersion, log: log)
        if let log, !issue.logInline { app.handOver(log: log) }
        app.open(issue.url)
        model.log.write("opened a \(kind == .bug ? "bug report" : "feature request") on GitHub")
        close()
    }
}
