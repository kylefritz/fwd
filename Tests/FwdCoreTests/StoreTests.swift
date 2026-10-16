import Foundation
import Testing
@testable import FwdCore

func tempPaths() -> Paths {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-t-\(UUID().uuidString)")
    return Paths.fromEnvironment(["FWD_HOME": base.path])
}

@Suite struct StoreTests {
    @Test func roundTrip() throws {
        let store = Store(paths: tempPaths())
        let file = PortsFile(hosts: [
            "devbox": [Entry(port: "3000"), Entry(port: "3*** -> 4***", on: false)],
            "homelab": [Entry(port: "8080")],
        ])
        try store.savePorts(file)
        #expect(try store.loadPorts() == file)
        let text = try String(contentsOf: store.paths.portsFile, encoding: .utf8)
        #expect(text.contains("devbox"))
        #expect(text.contains("3*** -> 4***"))
    }

    @Test func keepConnectedIsSavedOnlyWhenSet() throws {
        let store = Store(paths: tempPaths())
        let file = PortsFile(hosts: ["vdesk": [Entry(port: "8765", keep: true), Entry(port: "8080")]])
        try store.savePorts(file)
        #expect(try store.loadPorts() == file)
        let text = try String(contentsOf: store.paths.portsFile, encoding: .utf8)
        #expect(text.components(separatedBy: "keep").count == 2, "only the kept entry writes the key")
        #expect(try Store.decodePorts("hosts:\n  vdesk:\n  - port: 8765\n").hosts["vdesk"]?.first?.keep == false)
    }

    @Test func theInstallIDIsStableAndSurvivesSavingPorts() throws {
        let store = Store(paths: tempPaths())
        let id = store.installID()
        #expect(UUID(uuidString: id) != nil)
        store.saveSticky(["devbox|3000|3000": 3001])
        #expect(store.installID() == id)
        #expect(store.loadSticky() == ["devbox|3000|3000": 3001])
    }

    @Test func aMissingSettingsFileIsCreatedWithEveryOptionExplained() throws {
        let store = Store(paths: tempPaths())
        try store.ensurePreferencesFile()
        let text = try String(contentsOf: store.paths.preferencesFile, encoding: .utf8)
        for key in ["check_for_updates", "send_usage_stats", "update_channel"] { #expect(text.contains(key)) }
        #expect(store.loadPreferences() == Preferences(), "the file as written means the defaults")

        try "update_channel: beta\n".write(to: store.paths.preferencesFile, atomically: true, encoding: .utf8)
        try store.ensurePreferencesFile()
        #expect(store.loadPreferences().updateChannel == .beta, "an existing file is left alone")
    }

    @Test func missingAndEmptyFilesAreEmpty() throws {
        let store = Store(paths: tempPaths())
        #expect(try store.loadPorts() == PortsFile())
        for text in ["", "\n\n", "# just a comment\n", "hosts:\n", "hosts: {}\n", "hosts:\n  devbox:\n"] {
            let parsed = try Store.decodePorts(text)
            let allEmpty = parsed.hosts.values.allSatisfy { $0.isEmpty }
            #expect(allEmpty, "for \(text.debugDescription)")
        }
    }

    @Test func handWrittenFormsAreAccepted() throws {
        let parsed = try Store.decodePorts("""
        # my ports
        hosts:
          devbox:
            - port: 3000
            - port: "31**"
              on: false
            - {port: 80 -> 8080, on: true}
        """)
        #expect(parsed.hosts["devbox"] == [
            Entry(port: "3000", on: true), Entry(port: "31**", on: false), Entry(port: "80 -> 8080", on: true),
        ])
    }

    @Test(arguments: [
        "hosts: [1, 2",
        "hosts: 5\n",
        "hosts:\n  devbox: nope\n",
        "hosts:\n  devbox:\n    - 3000\n",
        "- just\n- a list\n",
        "hosts:\n  devbox:\n    - port: 3000\n      on: maybe\n",
    ])
    func malformedFilesThrowRatherThanLoadEmpty(_ text: String) {
        #expect(throws: (any Error).self) { try Store.decodePorts(text) }
    }

    @Test func stickyRoundTripAndMissingFile() {
        let store = Store(paths: tempPaths())
        #expect(store.loadSticky().isEmpty)
        store.saveSticky(["devbox|3000|3000": 3001])
        #expect(store.loadSticky() == ["devbox|3000|3000": 3001])
    }

    @Test func preferencesDefaultOnAndCanBeTurnedOff() throws {
        let store = Store(paths: tempPaths())
        #expect(store.loadPreferences().checkForUpdates)
        try FileManager.default.createDirectory(at: store.paths.configDir, withIntermediateDirectories: true)
        try "check_for_updates: false\n".write(to: store.paths.preferencesFile, atomically: true, encoding: .utf8)
        #expect(!store.loadPreferences().checkForUpdates)
        try "nonsense: [".write(to: store.paths.preferencesFile, atomically: true, encoding: .utf8)
        #expect(store.loadPreferences().checkForUpdates)
    }

    @Test func logAppendsAndRotates() throws {
        let paths = tempPaths()
        let log = Log(file: paths.logFile, maxBytes: 200)
        log.write("connected", host: "devbox")
        log.flush()
        let first = try String(contentsOf: paths.logFile, encoding: .utf8)
        #expect(first.contains("[devbox] connected"))
        for i in 0..<20 { log.write("line \(i) with some padding to grow the file") }
        log.flush()
        let rolled = paths.logFile.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: rolled.path))
        let size = try FileManager.default.attributesOfItem(atPath: paths.logFile.path)[.size] as! Int
        #expect(size < 400)
    }

    @Test func handWrittenPortsAreReadInTheAppsSpelling() throws {
        let file = try Store.decodePorts("hosts:\n  devbox:\n  - port: 3000->4000\n  - port: \"03001\"\n  - port: banana\n")
        #expect(file.hosts["devbox"]?.map(\.port) == ["3000 -> 4000", "3001", "banana"])
    }
}
