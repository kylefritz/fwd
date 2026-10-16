import Foundation
import Testing
@testable import FwdCore

@Suite struct ConnectionTests {
    @Test func eachConnectionHasItsOwnControlSocket() {
        // A stale connection being stopped must never remove the socket of
        // the one that replaced it.
        let paths = tempPaths()
        let log = Log(file: paths.logFile)
        let a = SSHConnection(host: "devbox", paths: paths, log: log)
        let b = SSHConnection(host: "devbox", paths: paths, log: log)
        #expect(a.socketPath != b.socketPath)
        #expect(a.socketPath.hasPrefix(paths.socketDir.path))
        #expect(a.socketPath.utf8.count < 100)
    }

    @Test func aSocketFolderSomeoneElseCouldWriteIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-sock-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o777])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Ours but too open: tightened, not refused.
        try SSHConnection.prepareSocketDir(dir)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)

        let link = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-link-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(throws: ConnectionError.self) { try SSHConnection.prepareSocketDir(link) }
    }
}
