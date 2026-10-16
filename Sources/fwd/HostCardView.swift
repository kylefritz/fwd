import FwdCore
import SwiftUI

/// How one state looks: a symbol with its own shape, a color, and words.
struct StateStyle {
    let symbol: String
    let color: Color
    let words: String

    static func pill(_ state: PillState) -> StateStyle {
        switch state {
        case .off: return StateStyle(symbol: "circle.dashed", color: .secondary, words: "off")
        case .pending: return StateStyle(symbol: "ellipsis.circle", color: .secondary, words: "waiting for the host")
        case .waiting: return StateStyle(symbol: "circle", color: .secondary, words: "forwarded, nothing listening on the remote yet")
        case .live: return StateStyle(symbol: "circle.fill", color: .green, words: "live: a server is listening")
        case .active: return StateStyle(symbol: "bolt.circle.fill", color: .green, words: "in use right now")
        case .blocked(let why): return StateStyle(symbol: "exclamationmark.triangle.fill", color: .orange, words: "blocked: \(why)")
        case .invalid(let why): return StateStyle(symbol: "xmark.octagon.fill", color: .red, words: "not a valid entry: \(why)")
        }
    }

    static func host(_ state: HostState) -> StateStyle {
        switch state {
        case .idle: return StateStyle(symbol: "circle.dashed", color: .secondary, words: "idle")
        case .standby: return StateStyle(symbol: "circle.dashed", color: .secondary, words: "not connected")
        case .connecting: return StateStyle(symbol: "ellipsis.circle", color: .secondary, words: "connecting")
        case .connected: return StateStyle(symbol: "checkmark.circle.fill", color: .green, words: "connected")
        case .retrying: return StateStyle(symbol: "arrow.triangle.2.circlepath", color: .orange, words: "reconnecting")
        case .paused: return StateStyle(symbol: "pause.circle", color: .secondary, words: "paused")
        case .needsAttention: return StateStyle(symbol: "exclamationmark.triangle.fill", color: .orange, words: "needs attention")
        }
    }

    static func config(_ status: ConfigForwardStatus) -> StateStyle {
        switch status {
        case .on: return StateStyle(symbol: "circle.fill", color: .green, words: "on")
        case .notForwarded: return StateStyle(symbol: "circle", color: .secondary, words: "not forwarded")
        case .taken(let by): return StateStyle(symbol: "exclamationmark.triangle.fill", color: .orange, words: "port taken by \(by)")
        case .unknown: return StateStyle(symbol: "questionmark.circle", color: .secondary, words: "unknown")
        }
    }
}

struct HostCardView: View {
    let card: HostCard
    let model: AppModel
    let app: AppDelegate
    let report: (Error) -> Void

    private var needsAttention: Bool {
        if case .needsAttention = card.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if needsAttention { attention }
            if !card.pills.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(card.pills) { pill in
                        PillView(pill: pill, host: card.name, model: model, app: app, report: report)
                    }
                }
            }
            if !card.configPills.isEmpty { configSection }
            if card.inConfig {
                PortField(host: card.name, model: model)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .inset(by: 0.5).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        .opacity(card.inConfig ? 1 : 0.6)
        .animation(.snappy(duration: 0.25), value: card)
    }

    private var header: some View {
        let style = StateStyle.host(card.state)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(card.name).font(.headline).lineLimit(1).truncationMode(.middle)
            if card.inConfig { ScreenSharingButton(host: card.name, model: model, app: app, report: report) }
            if card.state != .idle {
                Image(systemName: style.symbol).foregroundStyle(style.color).font(.caption)
                    .accessibilityLabel(style.words)
                if !needsAttention {
                    Text(card.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !card.inConfig {
                Text("not in ssh config").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if card.state == .standby {
                Button("Connect") { Task { await model.connect(host: card.name) } }
                    .buttonStyle(.link).font(.caption)
                    .help("Connect now. fwd won't reconnect by itself if the link drops, unless you're ssh'd into \(card.name) or a port is set to Keep connected.")
            }
            if !card.pills.isEmpty {
                Button("Remove All Ports") {
                    Task { do { try await model.clearAll(host: card.name) } catch { report(error) } }
                }
                .buttonStyle(.link).font(.caption)
                .help("Remove every port from \(card.name), on or off. Nothing on the remote changes.")
            }
        }
    }

    private var attention: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.statusLine).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Button("Retry") { Task { await model.connect(host: card.name) } }
                Button("Open in Terminal") { app.openInTerminal(host: card.name) }
                    .help("Runs ssh \(card.name) so you can answer whatever ssh is asking for")
            }
            .controlSize(.small)
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From your ssh config").font(.caption2).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(card.configPills) { ConfigPillView(pill: $0) }
            }
        }
    }
}

/// One click: forward the host's port 5900 and open it in Screen Sharing.
struct ScreenSharingButton: View {
    let host: String
    let model: AppModel
    let app: AppDelegate
    let report: (Error) -> Void

    @State private var opening = false

    var body: some View {
        Button(action: open) {
            if opening {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "display")
            }
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .disabled(opening)
        .help(Text(verbatim: "Screen Sharing: forward \(host)'s port 5900 and open it"))
        .accessibilityLabel(Text(verbatim: "Share the screen of \(host)"))
    }

    private func open() {
        opening = true
        Task {
            defer { opening = false }
            do { app.open(try await model.screenSharingURL(host: host)) } catch { report(error) }
        }
    }
}

struct ConfigPillView: View {
    let pill: ConfigPill

    var body: some View {
        let style = StateStyle.config(pill.status)
        let kind = pill.forward.kind == .local ? "LocalForward" : "RemoteForward"
        let arrow = pill.forward.kind == .local ? "←" : "→"
        HStack(spacing: 4) {
            Image(systemName: style.symbol).foregroundStyle(style.color).font(.caption2)
            Text(verbatim: "\(pill.forward.listenPort) \(arrow)").font(.caption.monospacedDigit())
            Text("config").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .help(Text(verbatim: "\(kind) \(pill.forward.listenPort) \(pill.forward.target): \(style.words). Opened by your own ssh sessions, not by fwd."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(kind) \(pill.forward.listenPort), from ssh config, \(style.words)"))
    }
}

struct PillView: View {
    let pill: Pill
    let host: String
    let model: AppModel
    let app: AppDelegate
    let report: (Error) -> Void

    @State private var overPill = false
    @State private var overRemove = false
    /// The remove badge stays while the mouse is on the pill or on the badge,
    /// which sticks out past the pill's edge.
    private var hovering: Bool { overPill || overRemove }
    @State private var renaming = false
    @State private var draftName = ""

    private var isUp: Bool { pill.state == .live || pill.state == .active }

    var body: some View {
        let style = StateStyle.pill(pill.state)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Button(action: toggle) {
                    HStack(spacing: 5) {
                        Image(systemName: style.symbol).foregroundStyle(style.color).font(.caption)
                        if let name = pill.name {
                            Text(verbatim: name).font(.callout.weight(.semibold))
                                .foregroundStyle(pill.on ? .primary : .secondary)
                        }
                        Text(verbatim: pill.label.replacingOccurrences(of: "->", with: "→")).font(pill.name == nil ? .callout.monospacedDigit() : .caption.monospacedDigit())
                            .foregroundStyle(pill.on && pill.name == nil ? .primary : .secondary)
                        if pill.keep {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                                .help(PillView.keepHelp)
                                .accessibilityLabel("keep connected")
                        }
                        if pill.moved {
                            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.orange)
                                .accessibilityLabel("moved to a nearby port")
                        }
                        if pill.isWildcard, pill.on, !pill.ports.isEmpty {
                            Text(verbatim: "\(pill.ports.count)").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(style))
                .accessibilityLabel("\(pill.name.map { "\($0), " } ?? "")\(pill.label), \(style.words)")
                .accessibilityHint(pill.on ? "Turns this forward off" : "Turns this forward on")

                if let url = pill.openURL, pill.on, pill.state != .pending {
                    Button { app.open(url) } label: {
                        Image(systemName: pill.isScreenSharing ? "display" : "arrow.up.right.square")
                    }
                    .buttonStyle(.plain).foregroundStyle(isUp ? .blue : .secondary)
                    .help(Text(verbatim: "Open \(url.absoluteString)"))
                    .accessibilityLabel(Text(verbatim: "Open \(url.absoluteString)"))
                }
            }
            if pill.isWildcard, pill.on, !pill.ports.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pill.ports) { port in
                        let portStyle = StateStyle.pill(port.state)
                        if let local = port.local, let url = port.openURL {
                            Button { app.open(url) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: portStyle.symbol).foregroundStyle(portStyle.color).font(.caption2)
                                    Text(verbatim: port.remote == local ? "\(port.remote)" : "\(port.remote) → \(local)")
                                        .font(.caption.monospacedDigit())
                                    Image(systemName: "arrow.up.right.square").font(.caption2).foregroundStyle(.blue)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(Text(verbatim: "Open \(url.absoluteString)"))
                            .accessibilityLabel(Text(verbatim: "Port \(port.remote) on laptop \(local), \(portStyle.words)"))
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: portStyle.symbol).foregroundStyle(portStyle.color).font(.caption2)
                                Text(verbatim: "\(port.remote)").font(.caption.monospacedDigit())
                            }
                            .help(Text(verbatim: portStyle.words))
                            .accessibilityLabel(Text(verbatim: "Port \(port.remote), \(portStyle.words)"))
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .inset(by: 0.5)
                .stroke(pill.on ? style.color.opacity(0.35) : Color.secondary.opacity(0.25), lineWidth: 1))
        .onHover { overPill = $0 }
        // On top of the pill's corner rather than in its row, so showing it
        // doesn't widen the pill and push the next one along.
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(.background).padding(1))
                }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel("Remove \(pill.text)")
                .offset(x: 6, y: -6)
                .onHover { overRemove = $0 }
            }
        }
        .popover(isPresented: $renaming, arrowEdge: .bottom) {
            HStack {
                TextField("Name, like api or vnc", text: $draftName)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit(saveName)
                Button("Save", action: saveName).keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .contextMenu {
            Button(pill.on ? "Turn off" : "Turn on", action: toggle)
            Toggle("Keep connected", isOn: Binding(get: { pill.keep }, set: setKeep))
                .help(PillView.keepHelp)
            Button("Rename…") {
                draftName = pill.name ?? ""
                renaming = true
            }
            if let local = pill.local { Button("Copy localhost:" + String(local)) { app.copy("localhost:\(local)") } }
            Button("Remove", action: remove)
        }
    }

    private var background: Color {
        guard pill.on else { return Color.secondary.opacity(0.06) }
        switch pill.state {
        case .live, .active: return Color.green.opacity(0.13)
        case .blocked, .invalid: return Color.orange.opacity(0.13)
        default: return Color.secondary.opacity(0.1)
        }
    }

    private func help(_ style: StateStyle) -> String {
        var text = style.words.prefix(1).uppercased() + style.words.dropFirst()
        if pill.moved, let local = pill.local {
            text += ". The laptop port you asked for was taken, so this is on \(local)."
        }
        if pill.keep { text += ". Kept connected." }
        return text + (pill.on ? " Click to turn off." : " Click to turn on.")
    }

    static let keepHelp = """
        Keep connected: while this port is on, fwd keeps the host connected and reconnects \
        after drops, sleep and network changes, even with no ssh session open. Without it, \
        fwd connects only while you're ssh'd into the host, or once when you click.
        """

    private func toggle() {
        Task { do { try await model.toggle(host: host, text: pill.text) } catch { report(error) } }
    }

    private func setKeep(_ keep: Bool) {
        Task { do { try await model.setKeep(host: host, text: pill.text, keep: keep) } catch { report(error) } }
    }

    private func saveName() {
        renaming = false
        Task { do { try await model.rename(host: host, text: pill.text, to: draftName) } catch { report(error) } }
    }

    private func remove() {
        Task { do { try await model.remove(host: host, text: pill.text) } catch { report(error) } }
    }
}
