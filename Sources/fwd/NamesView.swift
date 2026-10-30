import FwdCore
import SwiftUI

/// The Open Forwards by Name window.
struct NamesView: View {
    @ObservedObject var model: AppModel
    let open: (URL) -> Void
    let close: () -> Void

    var body: some View {
        NamesContent(state: model.namesState, saved: model.openByNameSaved, addresses: model.addressBook.addresses,
                     set: { on in Task { await model.setOpenByName(on) } }, open: open, close: close)
    }
}

/// Everything in the window, given its data, so `--snapshot-names` can draw
/// each state.
struct NamesContent: View {
    let state: NamesState
    /// Whether the setting is on, which it can be while port 80 is busy.
    let saved: Bool
    let addresses: [ForwardAddress]
    let set: (Bool) -> Void
    var open: (URL) -> Void = { _ in }
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .off: off
            case .on: on
            case .failed(let message): failed(message)
            }
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
    }

    @ViewBuilder private var off: some View {
        if let first = addresses.first(where: { !$0.duplicate }) {
            Text(verbatim: "Type \(first.address) instead of localhost:\(first.remote)").font(.headline)
        } else {
            Text("Type a forward's name instead of its port").font(.headline)
        }
        rows(showingStatus: false)
        VStack(alignment: .leading, spacing: 2) {
            Text("What this changes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("fwd listens on port 80 so you can leave out the port number. It refuses connections from other computers.")
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("You can turn this off here at any time.").foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Button("Turn On") { set(true) }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var on: some View {
        HStack(spacing: 6) {
            Text("On").font(.caption.weight(.semibold)).foregroundStyle(.green)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Color.green.opacity(0.15), in: Capsule())
            Text("Named forwards open at name.localhost").foregroundStyle(.secondary)
        }
        rows(showingStatus: true)
        Text("Rename a forward to change its address. Forwards without a name don't get one.")
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Turn Off", role: .destructive) { set(false) }
            Spacer()
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func failed(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
        Text(retryAdvice).fixedSize(horizontal: false, vertical: true)
        HStack {
            if saved { Button("Turn Off", role: .destructive) { set(false) } }
            Spacer()
            Button("Done", action: close).keyboardShortcut(.cancelAction)
            Button("Try Again") { set(true) }.keyboardShortcut(.defaultAction)
        }
    }

    private var retryAdvice: String {
        guard let first = addresses.first(where: {
            if case .ready = $0.status { return !$0.duplicate }
            return false
        }), case .ready(let local) = first.status else {
            return "Free the port, then try again."
        }
        return "Free the port, then try again. Until then, \(first.address):\(local) still works with the port number."
    }

    @ViewBuilder private func rows(showingStatus: Bool) -> some View {
        if addresses.isEmpty {
            Text("No named forwards yet. Add one like 3000 web, or rename one in the panel.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 0) {
                ForEach(addresses) { row($0, showingStatus: showingStatus) }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ address: ForwardAddress, showingStatus: Bool) -> some View {
        HStack(spacing: 8) {
            if showingStatus {
                Circle().fill(isUp(address) ? Color.green : Color.clear)
                    .overlay(Circle().stroke(isUp(address) ? Color.green : Color.secondary, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
            }
            if showingStatus, !address.duplicate, let url = URL(string: "http://\(address.address)") {
                Button(address.address) { open(url) }.buttonStyle(.link).fontWeight(.semibold)
            } else {
                Text(address.address).fontWeight(.semibold).foregroundStyle(address.duplicate ? .secondary : .primary)
            }
            Spacer(minLength: 8)
            Text(showingStatus ? statusText(address) : "\(address.host), localhost:\(address.remote)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func isUp(_ address: ForwardAddress) -> Bool {
        if case .ready = address.status { return !address.duplicate }
        return false
    }

    private func statusText(_ address: ForwardAddress) -> String {
        if address.duplicate { return "\(address.host), rename: address taken" }
        switch address.status {
        case .off: return "\(address.host), off"
        case .notConnected: return "\(address.host), not connected"
        case .connecting: return "\(address.host), connecting"
        case .waiting: return "\(address.host), nothing listening"
        case .ready(let local): return "\(address.host), localhost:\(local)"
        case .needsPerson: return "\(address.host), needs you"
        case .blocked: return "\(address.host), blocked"
        }
    }
}

/// `--snapshot-names`: the window in each state, for checking the layout.
struct NamesSnapshot: View {
    private static let addresses = [
        ForwardAddress(address: "api.localhost", name: "api", host: "devbox", text: "8080", remote: 8080, status: .notConnected),
        ForwardAddress(address: "web.localhost", name: "web", host: "devbox", text: "8765", remote: 8765,
                       status: .ready(local: 8765)),
    ]
    private static let more = addresses + [
        ForwardAddress(address: "web.localhost", name: "my web", host: "devbox", text: "9000", remote: 9000, status: .off,
                       duplicate: true),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                frame(.off, saved: false, Self.addresses)
                frame(.off, saved: false, [])
            }
            VStack(alignment: .leading, spacing: 16) {
                frame(.on, saved: true, Self.more)
                frame(.failed("Port 80 is in use by nginx, so fwd can't listen there."), saved: true, Self.addresses)
            }
        }
        .padding(16)
    }

    private func frame(_ state: NamesState, saved: Bool, _ addresses: [ForwardAddress]) -> some View {
        NamesContent(state: state, saved: saved, addresses: addresses, set: { _ in })
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
    }
}
