import Foundation

/// What a `fwd` command line asks for.
public enum Invocation: Equatable {
    case openWindow
    case version
    case help
    /// Print instructions for coding agents; no app needed.
    case agents
    case request(ControlRequest, json: Bool)
    /// Bad usage, with the message to print; exit 2. `json` says the
    /// command line asked for JSON, so the error goes out as JSON too.
    case usage(String, json: Bool)
}

/// Turns `fwd`'s arguments into an invocation. Hosts and ports aren't
/// checked here: only the app knows the hosts, so it resolves them.
public enum CLIArguments {
    public static let commands = ["forward", "status", "wait", "off", "remove", "keep", "connect", "screen"]

    public static func parse(_ args: [String]) -> Invocation {
        // A bare fwd only explains itself, so trying it has no side effects.
        if args.isEmpty { return .help }
        if args == ["--version"] || args == ["-v"] { return .version }
        if args.contains("--help") || args.contains("-h") { return .help }
        if args == ["agents"] { return .agents }
        // Known up front, so even a mistake in the arguments answers in JSON.
        let wantsJSON = args.contains("--json")
        func usage(_ message: String) -> Invocation { .usage(message, json: wantsJSON) }

        var json = false, keep = false, wait = false, off = false, all = false
        var timeout: Double?
        var words: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            switch arg {
            case "--json": json = true
            case "--keep": keep = true
            case "--wait": wait = true
            case "--off": off = true
            case "--all": all = true
            case "--timeout":
                guard i < args.count else { return usage("--timeout needs a number of seconds") }
                guard let seconds = Double(args[i]), seconds > 0 else {
                    return usage("--timeout needs a number of seconds, not \"\(args[i])\"")
                }
                timeout = seconds
                i += 1
            default:
                if arg.hasPrefix("--timeout=") {
                    guard let seconds = Double(arg.dropFirst("--timeout=".count)), seconds > 0 else {
                        return usage("--timeout needs a number of seconds")
                    }
                    timeout = seconds
                } else if arg.hasPrefix("-"), arg.count > 1, Double(arg) == nil {
                    return usage("unknown option \(arg) (try fwd --help)")
                } else {
                    words.append(arg)
                }
            }
        }
        guard let first = words.first else { return usage("say what to do, like: fwd 3000 (try fwd --help)") }
        if first == "open" {
            guard words.count == 1 else {
                return usage("open takes no arguments; to forward on a host called open: fwd forward open \(words[1])")
            }
            return .openWindow
        }
        let isCommand = commands.contains(first)
        return .request(ControlRequest(cmd: isCommand ? first : "forward",
                                       args: isCommand ? Array(words.dropFirst()) : words,
                                       keep: keep, wait: wait, off: off, all: all, timeout: timeout),
                        json: json)
    }

    public static let help = """
        fwd: SSH port forwarding for the macOS menu bar

        Usage:
          fwd open                           open the fwd window
          fwd [host] <port>...               forward ports and print their local URLs
          fwd forward [host] <port>...       the same, spelled out
          fwd status [host] [--all]          hosts and ports with their live state
          fwd wait [host] <port>             wait until a server answers on the port
          fwd off [host] <port>...           turn ports off (they stay in the list)
          fwd remove [host] <port>...        remove ports from the list
          fwd keep [host] <port>... [--off]  keep the host connected for these ports
          fwd connect [host]                 connect a host now
          fwd screen [host]                  open the host's screen in Screen Sharing
          fwd --version                      print the version
          fwd agents                         instructions to give a coding agent

        Options:
          --json          print one JSON object, errors included
          --keep          (forward) also keep the host connected
          --wait          (forward) also wait until a server answers
          --timeout S     seconds to wait (forward 30, connect 30, wait 60)

        The host can be left out when exactly one host is connected.
        Ports: 3000   "3000->4000"   "31**" (3100-3199)   "5173 web" (with a name)
        Quote ports with -> or *: the shell reads > as a redirect and * as a
        filename pattern.

        Exit codes:
          0 done
          1 couldn't do it (the reason is printed)
          2 bad usage
          3 the fwd app couldn't be reached
          4 timed out

        Ports and settings: ~/.config/fwd/   Log: ~/Library/Logs/fwd/fwd.log
        """

    /// What `fwd agents` prints: a block for a coding agent's instructions
    /// (CLAUDE.md, AGENTS.md). The README carries the same text, and a test
    /// keeps the two identical.
    public static let agentInstructions = """
        ## fwd: reaching servers on remote hosts

        fwd forwards ports from ssh hosts to this Mac. Use it when something you
        run here (a browser, curl, tests) needs a server on a remote host.

        - `fwd <host> <port> --wait --json` forwards the port and waits until a
          server answers. The local URL is in `host.ports[0].url`; it can be a
          different local port than the remote one.
        - `fwd status --json` lists hosts, their state and forwarded ports with
          URLs. Check it instead of guessing ports.
        - `fwd <host> <port> --json` forwards without waiting (state `waiting`
          means nothing listens on the remote yet); `fwd wait <host> <port>`
          waits later.
        - `fwd off <host> <port>` turns a forward off when you're done.
        - The host can be left out when exactly one host is connected.
        - Exit codes: 0 done, 1 couldn't (read `error`), 2 bad usage, 3 the fwd
          app isn't reachable, 4 timed out.
        - Don't add `--keep` unless asked: it keeps the host connected after
          the session that started it ends.
        - `fwd --help` lists everything.
        """
}
