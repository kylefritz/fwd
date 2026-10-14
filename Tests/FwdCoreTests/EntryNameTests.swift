import Foundation
import Testing
@testable import FwdCore

@MainActor
@Suite struct EntryNameTests {
    @Test func splitsATrailingNameOffThePort() {
        #expect(EntryName.split("3000 api") == ("3000", "api"))
        #expect(EntryName.split("  3000 -> 4000   web ") == ("3000 -> 4000", "web"))
        #expect(EntryName.split("31** dev-servers") == ("31**", "dev-servers"))
        #expect(EntryName.split("3000") == ("3000", nil))
        #expect(EntryName.split("3000 -> 4000") == ("3000 -> 4000", nil))
        #expect(EntryName.split("3000->4000") == ("3000->4000", nil))
    }

    @Test func namesAreTidied() {
        #expect(EntryName.clean("  ") == nil)
        #expect(EntryName.clean(" my\napi ") == "my api")
        #expect(EntryName.clean(String(repeating: "x", count: 40))?.count == EntryName.maxLength)
    }

    @Test func namesRoundTripThroughTheFileAndAreOptional() throws {
        let yaml = "hosts:\n  devbox:\n  - port: 3000\n    name: api\n  - port: \"4000\"\n"
        let file = try Store.decodePorts(yaml)
        #expect(file.hosts["devbox"] == [Entry(port: "3000", name: "api"), Entry(port: "4000")])
        let store = Store(paths: tempPaths())
        try store.savePorts(file)
        #expect(try store.loadPorts() == file)
    }

    @Test func addingWithANameAndRenaming() async throws {
        let rig = try AppModelTests.Rig()
        await rig.model.start(runTimer: false)
        try await rig.model.add(host: "devbox", text: "3000 api")
        #expect(rig.pill("devbox", "3000")?.name == "api")

        // Re-adding without a name keeps it; with a name replaces it.
        try await rig.model.add(host: "devbox", text: "3000")
        #expect(rig.pill("devbox", "3000")?.name == "api")
        try await rig.model.rename(host: "devbox", text: "3000", to: "web")
        #expect(rig.pill("devbox", "3000")?.name == "web")
        try await rig.model.turnAllOff()
        #expect(rig.pill("devbox", "3000")?.name == "web", "turning off keeps the name")
        try await rig.model.rename(host: "devbox", text: "3000", to: " ")
        #expect(rig.pill("devbox", "3000")?.name == nil)
        #expect(!rig.portsText.contains("name"))
        await rig.model.shutdown()
    }
}
