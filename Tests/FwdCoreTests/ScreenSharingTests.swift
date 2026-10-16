import Foundation
import Testing
@testable import FwdCore

@MainActor
@Suite struct ScreenSharingTests {
    typealias Rig = AppModelTests.Rig
    static let sharing = "#fwd:netstat\ntcp4 0 0 *.5900 *.* LISTEN\n"

    @Test func vncPortsOpenInScreenSharingAndOthersInTheBrowser() {
        #expect(ScreenSharing.url(remote: 5900, local: 5901).absoluteString == "vnc://localhost:5901")
        #expect(ScreenSharing.url(remote: 5905, local: 5905).absoluteString == "vnc://localhost:5905")
        #expect(ScreenSharing.url(remote: 3000, local: 3001).absoluteString == "http://localhost:3001")
        #expect(ScreenSharing.url(local: 5901, user: "sam").absoluteString == "vnc://sam@localhost:5901")
        #expect(ScreenSharing.url(local: 5901, user: nil).absoluteString == "vnc://localhost:5901")
    }

    @Test func readsTheLoginUserFromSSH() {
        #expect(ScreenSharing.user(sshG: "hostname mini.local\nuser sam\nport 22\n") == "sam")
        #expect(ScreenSharing.user(sshG: "hostname mini.local\n") == nil)
    }

    @Test func oneClickAddsTheForwardAndReturnsTheURL() async throws {
        let rig = try Rig(sshConfig: "Host mini\n  User sam\n")
        rig.box.listening = Self.sharing
        await rig.model.start(runTimer: false)
        let url = try await rig.model.screenSharingURL(host: "mini", timeout: 5)
        #expect(url.absoluteString == "vnc://sam@localhost:5901")
        #expect(try Store(paths: rig.model.paths).loadPorts().hosts["mini"] == [Entry(port: "5900 -> 5901", name: "vnc")])
        // Cards rebuild on a queued task, so wait for the forward to show.
        try await eventually("pill shows the forward") { rig.pill("mini", "5900 -> 5901")?.openURL != nil }
        let pill = try #require(rig.pill("mini", "5900 -> 5901"))
        #expect(pill.isScreenSharing)
        #expect(pill.name == "vnc")
        #expect(pill.openURL?.absoluteString == "vnc://localhost:5901")
        await rig.model.shutdown()
    }

    @Test func reusesAnExistingEntryInsteadOfAddingAnother() async throws {
        let rig = try Rig(sshConfig: "Host mini\n")
        rig.box.listening = Self.sharing
        await rig.model.start(runTimer: false)
        try await rig.model.add(host: "mini", text: "5900 -> 6000")
        try await rig.model.toggle(host: "mini", text: "5900 -> 6000")
        let url = try await rig.model.screenSharingURL(host: "mini", timeout: 5)
        #expect(url.port == 6000)
        #expect(try Store(paths: rig.model.paths).loadPorts().hosts["mini"] == [Entry(port: "5900 -> 6000")])
        await rig.model.shutdown()
    }

    @Test func secondHostGetsTheNextLaptopPort() async throws {
        let rig = try Rig(sshConfig: "Host mini\nHost studio\n")
        rig.box.listening = Self.sharing
        await rig.model.start(runTimer: false)
        #expect(try await rig.model.screenSharingURL(host: "mini", timeout: 5).port == 5901)
        #expect(try await rig.model.screenSharingURL(host: "studio", timeout: 5).port == 5902)
        await rig.model.shutdown()
    }

    @Test func saysSoWhenScreenSharingIsOff() async throws {
        let rig = try Rig(sshConfig: "Host mini\n")
        await rig.model.start(runTimer: false)
        await #expect(throws: ScreenSharingError.notSharing("mini")) {
            try await rig.model.screenSharingURL(host: "mini", timeout: 5)
        }
        await rig.model.shutdown()
    }
}
