import Foundation
import Testing
@testable import FwdCore

@Suite struct CLIArgumentsTests {
    func request(_ args: [String]) -> (ControlRequest, Bool)? {
        if case .request(let r, let json) = CLIArguments.parse(args) { return (r, json) }
        return nil
    }

    @Test func noArgumentsPrintsHelpAndOpenOpensTheWindow() {
        // A bare fwd has no side effects: an agent trying it gets text, not a window.
        #expect(CLIArguments.parse([]) == .help)
        #expect(CLIArguments.parse(["open"]) == .openWindow)
        #expect(CLIArguments.parse(["open", "--json"]) == .openWindow)
        if case .usage(let m, _) = CLIArguments.parse(["open", "3000"]) {
            #expect(m == "open takes no arguments; to forward on a host called open: fwd forward open 3000")
        } else { Issue.record("open with arguments should be usage") }
        #expect(CLIArguments.parse(["forward", "open", "3000"]) != .openWindow)
        #expect(CLIArguments.help.contains("fwd open"))
    }

    @Test func versionIsUntouched() {
        #expect(CLIArguments.parse(["--version"]) == .version)
        #expect(CLIArguments.parse(["-v"]) == .version)
        #expect(CLIArguments.parse(["--help"]) == .help)
        #expect(CLIArguments.parse(["-h"]) == .help)
    }

    @Test func forwardIsTheDefaultCommand() {
        #expect(request(["3000"])?.0 == ControlRequest(cmd: "forward", args: ["3000"]))
        #expect(request(["devbox", "3000", "5173", "web"])?.0
                == ControlRequest(cmd: "forward", args: ["devbox", "3000", "5173", "web"]))
        // An unknown word isn't rejected here: the app knows the hosts.
        #expect(request(["stauts"])?.0.cmd == "forward")
    }

    @Test func commandWordsWin() {
        for cmd in CLIArguments.commands {
            #expect(request([cmd, "devbox"])?.0.cmd == cmd)
        }
        #expect(request(["forward", "status", "3000"])?.0 == ControlRequest(cmd: "forward", args: ["status", "3000"]))
    }

    @Test func flagsGoAnywhere() throws {
        let (r, json) = try #require(request(["3000", "--keep", "--json", "--wait", "--timeout", "45"]))
        #expect(json)
        #expect(r == ControlRequest(cmd: "forward", args: ["3000"], keep: true, wait: true, timeout: 45))
        #expect(request(["--json", "status", "--all"])?.0 == ControlRequest(cmd: "status", all: true))
        #expect(request(["keep", "3000", "--off"])?.0 == ControlRequest(cmd: "keep", args: ["3000"], off: true))
        #expect(request(["wait", "3000", "--timeout=5"])?.0.timeout == 5)
    }

    @Test func badUsageIsCaughtHere() {
        if case .usage(let m, _) = CLIArguments.parse(["3000", "--frobnicate"]) { #expect(m.contains("--frobnicate")) }
        else { Issue.record("unknown flag should be usage") }
        if case .usage = CLIArguments.parse(["3000", "--timeout"]) {} else { Issue.record("missing value") }
        if case .usage = CLIArguments.parse(["3000", "--timeout", "soon"]) {} else { Issue.record("bad value") }
        if case .usage = CLIArguments.parse(["--json"]) {} else { Issue.record("flags alone") }
    }

    @Test func agentsPrintsInstructionsWithoutAskingTheApp() {
        #expect(CLIArguments.parse(["agents"]) == .agents)
        // A host that happens to be called "agents" is still reachable.
        #expect(request(["agents", "3000"])?.0 == ControlRequest(cmd: "forward", args: ["agents", "3000"]))
        let text = CLIArguments.agentInstructions
        for needle in ["--wait --json", "fwd status --json", "fwd off", "Exit codes", "--keep"] {
            #expect(text.contains(needle), "\(needle)")
        }
        #expect(CLIArguments.help.contains("fwd agents"))
    }

    @Test func theReadmeCarriesTheSameAgentInstructions() throws {
        let readme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        #expect(text.contains(CLIArguments.agentInstructions), "README's agent block must match `fwd agents` exactly")
    }

    @Test func usageErrorsKnowWhetherJSONWasAskedFor() {
        // An agent passing --json must get JSON back even when it made a mistake.
        #expect(CLIArguments.parse(["3000", "--json", "--timeout", "x"])
                == .usage("--timeout needs a number of seconds, not \"x\"", json: true))
        #expect(CLIArguments.parse(["--frobnicate", "--json"]) == .usage("unknown option --frobnicate (try fwd --help)", json: true))
        #expect(CLIArguments.parse(["3000", "--timeout"]) == .usage("--timeout needs a number of seconds", json: false))
    }

    @Test func helpQuotesPortsTheShellWouldMangle() {
        // Unquoted, -> is a redirect and ** a filename pattern.
        #expect(CLIArguments.help.contains("\"3000->4000\""))
        #expect(CLIArguments.help.contains("\"31**\""))
    }

    @Test func helpMentionsEveryCommandAndExitCode() {
        for cmd in CLIArguments.commands { #expect(CLIArguments.help.contains(cmd)) }
        for code in 0...4 { #expect(CLIArguments.help.contains("\(code) ")) }
    }
}
