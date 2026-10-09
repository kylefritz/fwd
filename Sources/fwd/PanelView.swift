import FwdCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater
    let app: AppDelegate
    let inWindow: Bool

    @State private var filter = ""
    @State private var actionError: String?

    private var filtered: [HostCard] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.cards }
        return model.cards.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            banners
            content
            Divider()
            FooterView(model: model, updater: updater, app: app, inWindow: inWindow, report: report)
        }
        .frame(maxHeight: inWindow ? .infinity : 560)
        .background(inWindow ? AnyShapeStyle(.windowBackground) : AnyShapeStyle(.clear))
        .onAppear { app.surfaceAppeared() }
        .onDisappear { app.surfaceDisappeared() }
    }

    private func report(_ error: Error) {
        actionError = message(for: error)
    }

    @ViewBuilder private var banners: some View {
        UpdateBanner(updater: updater, app: app)
        if let fileError = model.fileError {
            Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   title: "ports.yaml can't be read",
                   detail: "\(fileError)\nStill running on the last good version. Your file hasn't been changed.")
        }
        if let actionError {
            Banner(symbol: "xmark.octagon.fill", tint: .red, title: actionError, detail: nil) {
                self.actionError = nil
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.cards.isEmpty {
            EmptyStateView(configMissing: model.sshConfigMissing, configPath: model.paths.sshConfig.path, app: app)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.cards.count > 8 {
                        TextField("Filter hosts", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Filter hosts")
                    }
                    let prominent = filtered.filter(\.isProminent)
                    let others = filtered.filter { !$0.isProminent }
                    ForEach(prominent) { card in
                        HostCardView(card: card, model: model, app: app, report: report)
                    }
                    if !others.isEmpty {
                        if !prominent.isEmpty {
                            Text("Other hosts")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        VStack(spacing: 0) {
                            ForEach(others) { card in
                                CompactHostRow(card: card, model: model, report: report)
                                if card.id != others.last?.id { Divider() }
                            }
                        }
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if filtered.isEmpty {
                        Text("No hosts match \"\(filter)\"").foregroundStyle(.secondary).padding()
                    }
                }
                .padding(12)
            }
        }
    }
}

/// fwd's own errors read well as-is; system errors need their localized text.
func message(for error: Error) -> String {
    if error is PortPattern.ParseError || error is AppModelError { return "\(error)" }
    return error.localizedDescription
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }
}

struct UpdateBanner: View {
    @ObservedObject var updater: Updater
    let app: AppDelegate

    var body: some View {
        switch updater.state {
        case .ready(let version, let notes):
            row("fwd \(version) is ready") {
                if let notes { Button("What's new") { app.open(notes) }.buttonStyle(.link) }
                Button(updater.kind == .homebrew ? "Restart to finish updating" : "Restart to update") {
                    app.restartToUpdate()
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .available(let version, let notes):
            if updater.kind == .homebrew {
                row("fwd \(version) is available") {
                    Text("brew upgrade fwd").font(.caption.monospaced())
                    Button("Copy") { app.copy("brew upgrade fwd") }.controlSize(.small)
                }
            } else if let notes {
                row("fwd \(version) has been released") {
                    Button("Open release page") { app.open(notes) }.controlSize(.small)
                }
            }
        case .manual(let version, let page, let reason):
            row("fwd \(version) is available (\(reason))") {
                if let page { Button("Open release page") { app.open(page) }.controlSize(.small) }
            }
        case .idle, .checking, .upToDate:
            EmptyView()
        }
    }

    private func row(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(10)
        .background(Color.blue.opacity(0.1))
    }
}

struct EmptyStateView: View {
    let configMissing: Bool
    let configPath: String
    let app: AppDelegate

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.right.circle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(configMissing ? "No ssh config found" : "No hosts in your ssh config yet")
                .font(.headline)
            Text("fwd forwards ports for the hosts in \(configPath). Add a Host entry there and it will appear here. If `ssh <host>` works in a terminal, it works in fwd.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let url = URL(string: "https://github.com/\(Paths.repository)#readme") {
                Button("Read the guide") { app.open(url) }.buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The port field shared by cards and compact rows.
struct PortField: View {
    let host: String
    let model: AppModel
    var prompt = "Add a port: 3000, 31**, 3000 -> 4000"

    @State private var text = ""
    @State private var problem: String?
    @State private var shake = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .onSubmit(submit)
                .modifier(Shake(animatableData: CGFloat(shake)))
                .accessibilityLabel("Add a port for \(host)")
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func submit() {
        let entered = text
        guard !entered.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            do {
                try await model.add(host: host, text: entered)
                text = ""
                problem = nil
            } catch {
                problem = message(for: error)
                withAnimation(.linear(duration: 0.3)) { shake += 1 }
            }
        }
    }
}

struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 4), y: 0))
    }
}

struct CompactHostRow: View {
    let card: HostCard
    let model: AppModel
    let report: (Error) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(card.name).font(.callout).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            PortField(host: card.name, model: model, prompt: "port")
                .frame(width: 130)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

struct FooterView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater
    let app: AppDelegate
    let inWindow: Bool
    let report: (Error) -> Void

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var commandInstalled = CommandInstaller.isInstalled
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button("Turn all off") {
                    Task { do { try await model.turnAllOff() } catch { report(error) } }
                }
                .controlSize(.small)
                .disabled(!model.cards.contains { $0.pills.contains(where: \.on) })

                Spacer()
                Text(versionText).font(.caption).foregroundStyle(.secondary)

                Menu {
                    if !inWindow { Button("Open window") { app.showWindow() } }
                    Button("Open log") { app.openLog() }
                    Button("Copy log location") {
                        app.copyLogLocation()
                        note = "Copied \(model.paths.logFile.path)"
                    }
                    Divider()
                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { wanted in
                            if let problem = LoginItem.set(wanted) { note = "Launch at login: \(problem)" }
                            launchAtLogin = LoginItem.isEnabled
                        }))
                    if CommandInstaller.isOffered {
                        Button(commandInstalled ? "Terminal command installed" : "Install terminal command") {
                            installCommand()
                        }
                        .disabled(commandInstalled)
                    }
                    Button(updater.state == .checking ? "Checking for updates…" : "Check for updates") {
                        Task {
                            await updater.check()
                            if updater.state == .upToDate { note = "fwd \(updater.currentVersion) is the latest version." }
                            if updater.state == .idle { note = "Couldn't check for updates. See the log." }
                        }
                    }
                    .disabled(updater.state == .checking)
                    Divider()
                    Button("Quit fwd") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            commandInstalled = CommandInstaller.isInstalled
        }
    }

    private var versionText: String {
        updater.currentVersion == "dev" ? "dev build" : "v\(updater.currentVersion)"
    }

    private func installCommand() {
        do {
            try CommandInstaller.install()
            commandInstalled = CommandInstaller.isInstalled
            note = CommandInstaller.binDirOnPath
                ? "Installed. Type fwd in a terminal to open this window."
                : "Installed at \(CommandInstaller.link.path). Add this to your shell profile:\nexport PATH=\"$HOME/.local/bin:$PATH\""
        } catch {
            note = "Couldn't install the command: \(error.localizedDescription)"
        }
    }
}
