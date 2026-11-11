import Foundation

/// The small pages fwd answers an address with when it can't reach the app.
/// Everything from a request or a name is escaped, since any site can make a
/// browser ask for these.
enum NamePages {
    static func status(for page: NamePage) -> (code: Int, reason: String) {
        switch page {
        case .down: return (503, "Service Unavailable")
        case .unreachable: return (502, "Bad Gateway")
        case .several: return (200, "OK")
        case .unknown: return (404, "Not Found")
        }
    }

    static func html(for page: NamePage) -> String {
        switch page {
        case .down(let forward): return down(forward)
        case .unreachable(let forward):
            return document(title: "Can't reach \(forward.name)", reloads: true, """
                <p>fwd forwards port \(forward.remote) from \(escape(forward.host)), but the connection was refused.</p>
                """)
        case .several(let name, let forwards):
            let links = forwards.map {
                "<li><a href=\"http://\(escape($0.address))\">\(escape($0.address))</a></li>"
            }.joined()
            return document(title: "\(name) is on more than one host", reloads: false, "<ul>\(links)</ul>")
        case .unknown(let header):
            return document(title: "fwd doesn't know this name", reloads: false, """
                <p>Nothing is named <code>\(escape(String(header.prefix(100))))</code>. Give a forward a name, \
                like <code>3000 web</code>, and it opens at <code>web.\(ForwardAddress.domain)</code>.</p>
                """)
        }
    }

    private static func down(_ forward: ForwardAddress) -> String {
        let name = forward.name
        let forwards = "It forwards port \(forward.remote) from \(escape(forward.host))."
        switch forward.status {
        case .off:
            return document(title: "\(name) is off", reloads: true, """
                <p>\(forwards) Turn it on and this page reloads.</p>\(button("Turn On", action: NameAction.turnOn))
                """)
        case .notConnected:
            return document(title: "\(name) isn't connected", reloads: true, """
                <p>\(forwards) Connect and this page reloads.</p>\(button("Connect", action: NameAction.connect))
                """)
        case .connecting:
            return document(title: "Connecting to \(forward.host)…", reloads: true, """
                <p>\(escape(name)) opens when the connection is up.</p>
                """)
        case .waiting(let local):
            let anyway = local.map { "<p><a href=\"http://localhost:\($0)\">Try localhost:\($0) anyway</a></p>" } ?? ""
            return document(title: "Nothing is running on port \(forward.remote) yet", reloads: true, """
                <p>\(escape(forward.host)) is connected, but nothing is listening there. This page reloads when \
                \(escape(name)) comes up.</p>\(anyway)
                """)
        case .needsPerson(let message):
            return document(title: "\(forward.host) needs you", reloads: true, """
                <p>\(escape(message))</p><p>Open fwd in the menu bar to sort it out.</p>
                """)
        case .blocked(let reason):
            return document(title: "\(name) can't forward", reloads: true, """
                <p>\(escape(reason))</p><p>Open fwd in the menu bar for details.</p>
                """)
        case .ready:
            return document(title: "\(name) is up", reloads: true, "")
        }
    }

    private static func button(_ title: String, action: NameAction) -> String {
        "<form method=\"post\" action=\"\(action.path)\"><button type=\"submit\">\(title)</button></form>"
    }

    /// `title` is escaped here; `body` must already be.
    private static func document(title: String, reloads: Bool, _ body: String) -> String {
        let refresh = reloads ? "<meta http-equiv=\"refresh\" content=\"3\">" : ""
        return """
            <!doctype html><html lang="en"><head><meta charset="utf-8">\(refresh)
            <meta name="viewport" content="width=device-width, initial-scale=1"><title>\(escape(title))</title>
            <style>
            :root { color-scheme: light dark; }
            body { font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; max-width: 34rem;
                   margin: 18vh auto 0; padding: 0 16px; }
            h1 { font-size: 22px; margin: 0 0 8px; }
            p { margin: 0 0 12px; color: light-dark(#5b6878, #9aa8b8); }
            code { font: 13px ui-monospace, Menlo, monospace; }
            button { font: inherit; color: #fff; background: #0a66d8; border: 0; border-radius: 6px; padding: 5px 14px; }
            </style></head><body><h1>\(escape(title))</h1>\(body)</body></html>
            """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
