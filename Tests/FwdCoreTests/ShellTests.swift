import Foundation
import Testing
@testable import FwdCore

@Suite struct ShellTests {
    @Test func capturesOutputAndStatus() async {
        let result = await Shell.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(!result.ok)
    }

    @Test func largeOutputDoesNotDeadlock() async {
        let result = await Shell.run("/bin/sh", ["-c", "head -c 2000000 /dev/zero | tr '\\0' 'x'"])
        #expect(result.ok)
        #expect(result.stdout.utf8.count == 2_000_000)
    }

    @Test func aMissingProgramReportsFailure() async {
        let result = await Shell.run("/no/such/program", [])
        #expect(result.status == -1)
    }

    @Test func aProgramThatOverrunsItsTimeoutIsStopped() async {
        let started = Date()
        let result = await Shell.run("/bin/sleep", ["30"], timeout: 0.3)
        #expect(result.status == -1)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aProgramThatIgnoresTerminationStillReturns() async {
        let started = Date()
        let result = await Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 0.3)
        #expect(result.status == -1)
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func aBackgroundChildHoldingThePipesDoesNotHoldTheCall() async {
        let started = Date()
        let result = await Shell.run("/bin/sh", ["-c", "sleep 20 & echo started"], timeout: 15)
        #expect(result.ok)
        #expect(result.stdout == "started\n")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func manyAtOnceAllReturn() async {
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<60 {
                group.addTask { await Shell.run("/bin/sh", ["-c", "echo \(i)"]).stdout == "\(i)\n" }
            }
            for await ok in group { #expect(ok) }
        }
    }
}
