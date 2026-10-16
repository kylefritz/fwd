import Foundation
import Testing
@testable import FwdCore

@MainActor
@Suite(.serialized) struct CLIRunnerTests {
    @Test func startsTheAppOnceAndRetriesUntilItAnswers() async throws {
        let path = "/tmp/fwd-t-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(path: path) { _ in .success(hosts: []) }
        defer { server.stop() }
        final class Count: @unchecked Sendable { var launches = 0 }
        let count = Count()
        let reply = await Task.detached {
            CLIRunner.send(ControlRequest(cmd: "status"), socket: path, launch: {
                // Stands in for `open -g`: the app comes up a moment later.
                count.launches += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { try? server.start() }
            }, attempts: 50, delay: 0.05)
        }.value
        #expect(reply.ok, "\(reply)")
        #expect(count.launches == 1)
    }

    @Test func givesUpWithExitThree() async {
        let path = "/tmp/fwd-t-\(UUID().uuidString.prefix(8)).sock"
        let reply = await Task.detached {
            CLIRunner.send(ControlRequest(cmd: "status"), socket: path, launch: {}, attempts: 3, delay: 0.01)
        }.value
        #expect(reply.exitCode == .unreachable)
        #expect(reply.error == "couldn't reach the fwd app; is it installed? (open -a fwd)")
    }
}
