import FwdCore
import SwiftUI

/// Command Line Activity: every `fwd` command run since the app started,
/// with what ran it. A script or agent stuck in a loop shows as one row with
/// a high count and the programs above it.
struct CommandsView: View {
    @ObservedObject var log: CommandLog
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each fwd command run on this Mac since fwd started, newest first, with the programs that ran it. Something that runs one over and over shows here as a single row with a high count.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if log.entries.isEmpty {
                Text("No commands yet. Run `fwd status` in a terminal and it appears here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(log.entries) { CommandRow(entry: $0, copy: copy) }
                    }
                }
            }
            Text("Full command lines are shown only here. The log records program names, never arguments.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 260)
    }
}

private struct CommandRow: View {
    let entry: CommandLog.Entry
    let copy: (String) -> Void

    @State private var expanded = false

    private var looping: Bool { entry.count >= CommandLog.loopAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "fwd \(entry.command)").font(.callout.monospaced().weight(.medium))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if looping {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.caption)
                        .accessibilityLabel("run many times")
                }
                Text(verbatim: entry.count == 1 ? "once" : "\(entry.count) times")
                    .font(.callout.monospacedDigit().weight(looping ? .semibold : .regular))
                    .foregroundStyle(looping ? .orange : .secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "from \(entry.caller?.summary ?? "an unknown caller")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Text(entry.last, style: .relative).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("ago").font(.caption).foregroundStyle(.secondary)
            }
            if let caller = entry.caller {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(caller.chain) { step in
                            Text(verbatim: Self.line(step))
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("Copy") { copy(Self.text(entry)) }.controlSize(.small).padding(.top, 2)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Processes, from the command up").font(.caption)
                }
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private static func line(_ step: Caller.Step) -> String {
        let command = step.arguments.isEmpty ? step.name : step.arguments.joined(separator: " ")
        return "\(step.pid)  \(command)"
    }

    static func text(_ entry: CommandLog.Entry) -> String {
        var lines = ["fwd \(entry.command): \(entry.count) run\(entry.count == 1 ? "" : "s")"]
        lines += (entry.caller?.chain ?? []).map(line)
        return lines.joined(separator: "\n")
    }
}

/// `--snapshot-commands`: the window with made-up rows, for checking the layout.
struct CommandsSnapshot: View {
    @StateObject private var log: CommandLog = {
        let log = CommandLog()
        let terminal = Caller(chain: [
            .init(pid: 4410, name: "fwd", arguments: ["fwd", "status"]),
            .init(pid: 4302, name: "fish", arguments: ["-fish"]),
            .init(pid: 4301, name: "iTerm2", arguments: ["/Applications/iTerm.app/Contents/MacOS/iTerm2"]),
            .init(pid: 1, name: "launchd", arguments: ["/sbin/launchd"]),
        ])
        let looper = Caller(chain: [
            .init(pid: 9120, name: "fwd", arguments: ["fwd", "devbox", "7440"]),
            .init(pid: 9119, name: "sh", arguments: ["sh", "-c", "fwd devbox 7440"]),
            .init(pid: 811, name: "node", arguments: ["node", "/Users/me/tools/watcher/index.js", "--port", "7440"]),
            .init(pid: 1, name: "launchd", arguments: ["/sbin/launchd"]),
        ])
        let start = Date().addingTimeInterval(-3600)
        log.record(command: "status", caller: terminal, at: start)
        for i in 0..<412 {
            log.record(command: "forward devbox 7440", caller: looper, at: start.addingTimeInterval(Double(i) * 8.7))
        }
        return log
    }()

    var body: some View {
        CommandsView(log: log, copy: { _ in }).frame(width: 560)
    }
}
