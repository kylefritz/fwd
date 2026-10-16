import Foundation

/// What a `fwd` command line asks for.
public enum Invocation: Equatable {
    case openWindow
    case version
    case help
    case request(ControlRequest, json: Bool)
    /// Bad usage, with the message to print; exit 2.
    case usage(String)
}

/// Turns `fwd`'s arguments into an invocation. Hosts and ports aren't
/// checked here: only the app knows the hosts, so it resolves them.
public enum CLIArguments {
    public static let commands = ["forward", "status", "wait", "off", "remove", "keep", "connect", "screen"]

    public static func parse(_ args: [String]) -> Invocation {
        if args.isEmpty { return .openWindow }
        if args == ["--version"] || args == ["-v"] { return .version }
        if args.contains("--help") || args.contains("-h") { return .help }

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
                guard i < args.count else { return .usage("--timeout needs a number of seconds") }
                guard let seconds = Double(args[i]), seconds > 0 else {
                    return .usage("--timeout needs a number of seconds, not \"\(args[i])\"")
                }
                timeout = seconds
                i += 1
            default:
                if arg.hasPrefix("--timeout=") {
                    guard let seconds = Double(arg.dropFirst("--timeout=".count)), seconds > 0 else {
                        return .usage("--timeout needs a number of seconds")
                    }
                    timeout = seconds
                } else if arg.hasPrefix("-"), arg.count > 1, Double(arg) == nil {
                    return .usage("unknown option \(arg) (try fwd --help)")
                } else {
                    words.append(arg)
                }
            }
        }
        guard let first = words.first else { return .usage("say what to do, like: fwd 3000 (try fwd --help)") }
        let isCommand = commands.contains(first)
        return .request(ControlRequest(cmd: isCommand ? first : "forward",
                                       args: isCommand ? Array(words.dropFirst()) : words,
                                       keep: keep, wait: wait, off: off, all: all, timeout: timeout),
                        json: json)
    }

    public static let help = """
        fwd: SSH port forwarding for the macOS menu bar

        Usage:
          fwd                                open the fwd window
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

        Options:
          --json          print one JSON object, errors included
          --keep          (forward) also keep the host connected
          --wait          (forward) also wait until a server answers
          --timeout S     seconds to wait (forward 30, connect 30, wait 60)

        The host can be left out when exactly one host is connected.
        Ports: 3000   3000->4000   31** (3100-3199)   "5173 web" (with a name)

        Exit codes:
          0 done
          1 couldn't do it (the reason is printed)
          2 bad usage
          3 the fwd app couldn't be reached
          4 timed out

        Ports and settings: ~/.config/fwd/   Log: ~/Library/Logs/fwd/fwd.log
        """
}
