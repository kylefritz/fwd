import Testing
@testable import FwdCore

@Suite struct ReconcilerTests {
    func patterns(_ texts: String...) -> [PortPattern] { texts.map { try! PortPattern.parse($0) } }

    @Test func singlePortsAreWantedEvenWithNothingListening() {
        let d = Reconciler.desired(patterns: patterns("3000", "80 -> 8080"), listening: [])
        #expect(d == [DesiredPort(remote: 3000, wantedLocal: 3000, entry: "3000"),
                      DesiredPort(remote: 80, wantedLocal: 8080, entry: "80 -> 8080")])
        #expect(Reconciler.desired(patterns: patterns("3000"), listening: nil).count == 1)
    }

    @Test func wildcardsFollowTheScan() {
        let d = Reconciler.desired(patterns: patterns("3*** -> 4***"), listening: [22, 3001, 3999, 4000])
        #expect(d == [DesiredPort(remote: 3001, wantedLocal: 4001, entry: "3*** -> 4***"),
                      DesiredPort(remote: 3999, wantedLocal: 4999, entry: "3*** -> 4***")])
        #expect(Reconciler.desired(patterns: patterns("3***"), listening: nil).isEmpty)
    }

    @Test func earlierEntryWinsAnOverlap() {
        let d = Reconciler.desired(patterns: patterns("3000 -> 9000", "3***"), listening: [3000, 3001])
        #expect(d.map(\.wantedLocal) == [9000, 3001])
    }

    @Test func planAddsAndCancels() {
        let desired = [DesiredPort(remote: 3000, wantedLocal: 3000, entry: "3000"),
                       DesiredPort(remote: 3001, wantedLocal: 3001, entry: "3***")]
        let active = [Forward(remote: 3000, local: 3007, entry: "3000"),
                      Forward(remote: 3002, local: 3002, entry: "3***")]
        let plan = Reconciler.plan(desired: desired, active: active)
        #expect(plan.cancel == [Forward(remote: 3002, local: 3002, entry: "3***")])
        #expect(plan.add == [DesiredPort(remote: 3001, wantedLocal: 3001, entry: "3***")])
    }

    @Test func aForwardWhoseEntryChangedIsReplaced() {
        let desired = [DesiredPort(remote: 3000, wantedLocal: 9000, entry: "3000 -> 9000")]
        let active = [Forward(remote: 3000, local: 3000, entry: "3***")]
        let plan = Reconciler.plan(desired: desired, active: active)
        #expect(plan.cancel == active)
        #expect(plan.add == desired)
    }

    @Test func nothingToDoWhenInSync() {
        let desired = [DesiredPort(remote: 3000, wantedLocal: 3000, entry: "3000")]
        let plan = Reconciler.plan(desired: desired, active: [Forward(remote: 3000, local: 3001, entry: "3000")])
        #expect(plan.cancel.isEmpty && plan.add.isEmpty)
    }
}
