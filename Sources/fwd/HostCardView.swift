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
            if card.inConfig {
                ScreenSharingButton(host: card.name, model: model, app: app, report: report)
                VSCodeButton(host: card.name, model: model, app: app, report: report)
            }
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
            if card.inConfig || !card.pills.isEmpty { hostMenu }
        }
    }

    /// Less common host actions, kept off the card so the status line has room
    /// and removing every port takes more than one click.
    private var hostMenu: some View {
        Menu {
            if !card.pills.isEmpty {
                Button("Remove All Ports", role: .destructive) {
                    Task { do { try await model.clearAll(host: card.name) } catch { report(error) } }
                }
                .help("Remove every port from \(card.name), on or off. Nothing on the remote changes.")
            }
            if card.inConfig {
                if !card.pills.isEmpty { Divider() }
                Button("Open in Terminal") { app.openInTerminal(host: card.name) }
                    .help("Runs ssh \(card.name). fwd connects while that session is open.")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("More for \(card.name)")
        .accessibilityLabel(Text(verbatim: "More for \(card.name)"))
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

/// Opens a Remote-SSH window on the host in VS Code. Shows the editor's own
/// icon, and nothing when no such editor is installed. With herdr on, the
/// click opens a small menu instead: the host, or one of the directories its
/// herdr has open. herdr is asked as the menu opens, so "Open VS Code" never
/// waits on it.
struct VSCodeButton: View {
    let host: String
    let model: AppModel
    let app: AppDelegate
    let report: (Error) -> Void

    @State private var opening = false
    @State private var hovering = false
    @State private var showingMenu = false
    /// nil while herdr is being asked.
    @State private var listing: Herdr.Listing?
    /// Each click asks again; an older answer arriving late is dropped.
    @State private var ask = 0

    var body: some View {
        if let (editor, bundle) = app.vsCode {
            Button(action: click) {
                if opening {
                    ProgressView().controlSize(.mini)
                } else {
                    // A hidden symbol sets the size and baseline, so the icon
                    // lines up with Screen Sharing's symbol in any font.
                    Image(systemName: "square").hidden()
                        .overlay {
                            // Gray until hovered. App icons leave a margin
                            // around their art, so it's drawn a bit larger.
                            Image(nsImage: AppIcon.image(bundle, gray: !hovering && !showingMenu))
                                .resizable().interpolation(.high).scaledToFit()
                                .scaleEffect(1.25)
                                .opacity(hovering || showingMenu ? 1 : 0.75)
                        }
                }
            }
            .buttonStyle(.plain)
            .disabled(opening)
            .onHover { hovering = $0 }
            .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                HerdrMenu(host: host, editor: editor.name, listing: listing, open: open)
            }
            .help(Text(verbatim: "Open \(host) in \(editor.name) over Remote-SSH"))
            .accessibilityLabel(Text(verbatim: "Open \(host) in \(editor.name)"))
        }
    }

    private func click() {
        guard app.herdrMenu else { return open(nil) }
        ask += 1
        let mine = ask
        listing = nil
        showingMenu = true
        Task {
            let answer = await model.herdrDirectories(host: host)
            if ask == mine { listing = answer }
        }
    }

    private func open(_ folder: String?) {
        showingMenu = false
        opening = true
        Task {
            defer { opening = false }
            do { try await app.openInVSCode(host: host, folder: folder) } catch { report(error) }
        }
    }
}

/// The VS Code button's menu: the host itself, then herdr's directories.
/// Drawn to look like a menu, but a popover, so the herdr part can fill in
/// while it's open.
struct HerdrMenu: View {
    let host: String
    let editor: String
    let listing: Herdr.Listing?
    let open: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            MenuRow(action: { open(nil) }, help: "A new \(editor) window on \(host), with no folder open") {
                Text(verbatim: "Open \(editor)")
                Spacer(minLength: 12)
                Text(verbatim: "~").foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 4).padding(.horizontal, 6)
            Text(verbatim: "herdr").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.bottom, 2)
            herdr
        }
        .padding(5)
        .frame(minWidth: 240, maxWidth: 380, alignment: .leading)
    }

    @ViewBuilder private var herdr: some View {
        switch listing {
        case nil:
            note {
                ProgressView().controlSize(.small)
                Text("Loading…")
            }
        case .notInstalled?:
            note { Text(verbatim: "herdr isn't installed on \(host)") }
        case .notRunning?:
            note { Text(verbatim: "herdr isn't running on \(host)") }
        case .failed(let why)?:
            note { Text(why).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        case .directories(let dirs)?:
            if dirs.isEmpty {
                note { Text("No panes open in herdr") }
            } else {
                ForEach(dirs) { dir in
                    MenuRow(action: { open(dir.path) }, help: "Open \(dir.path) in \(editor)") {
                        HerdrDot(status: dir.status)
                        Text(dir.name).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(dir.display).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
            }
        }
    }

    private func note<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
    }
}

/// A row that highlights under the pointer, like a menu item.
private struct MenuRow<Label: View>: View {
    let action: () -> Void
    let help: String
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6, content: label)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Green: an agent is running there. Orange: one is waiting on you. Gray:
/// a pane is open with no agent.
struct HerdrDot: View {
    let status: Herdr.Status

    var body: some View {
        let (color, words): (Color, String) = switch status {
        case .agent: (.green, "agent running")
        case .blocked: (.orange, "agent waiting on you")
        case .none: (.gray, "no agent")
        }
        Circle().fill(color).frame(width: 7, height: 7)
            .help(words)
            .accessibilityLabel(words)
    }
}

/// An app's Finder icon, in color or gray, made once per app. Both come
/// from one bitmap: an icon holds several sizes with different margins, so
/// letting each pick its own would change the art's size on hover.
@MainActor
enum AppIcon {
    private static var cache: [String: NSImage] = [:]
    private static let pixels = 64

    static func image(_ app: URL, gray: Bool) -> NSImage {
        let key = "\(app.path)|\(gray)"
        if let cached = cache[key] { return cached }
        let color = cache[app.path] ?? bitmap(NSWorkspace.shared.icon(forFile: app.path))
        cache[app.path] = color
        let image = gray ? (grayscale(color) ?? color) : color
        cache[key] = image
        return image
    }

    private static func bitmap(_ icon: NSImage) -> NSImage {
        let size = NSSize(width: pixels, height: pixels)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func grayscale(_ image: NSImage) -> NSImage? {
        guard let rep = image.representations.first as? NSBitmapImageRep, let input = CIImage(bitmapImageRep: rep),
              let output = CIFilter(name: "CIPhotoEffectMono", parameters: [kCIInputImageKey: input])?.outputImage
        else { return nil }
        let gray = NSImage(size: image.size)
        gray.addRepresentation(NSCIImageRep(ciImage: output))
        return gray
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
            if pill.note != nil {
                Image(systemName: "info.circle").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .help(Text(verbatim: "\(kind) \(pill.forward.listenPort) \(pill.forward.target): \(style.words). Opened by your own ssh sessions, not by fwd.\(pill.note.map { "\n\($0)" } ?? "")"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(kind) \(pill.forward.listenPort), from ssh config, \(style.words)\(pill.note.map { ", \($0)" } ?? "")"))
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
