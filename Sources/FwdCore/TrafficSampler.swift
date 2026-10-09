import Foundation

/// Which forwarded laptop ports have a connection open right now.
///
/// This samples `nettop` for the ssh master. It sees connections that are
/// open at the moment of the sample, so a long-lived one (a websocket, a
/// stream, a slow request) shows reliably and a quick request can be missed.
public enum TrafficSampler {
    public static func busyPorts(masterPID: Int32) async -> Set<Int> {
        let result = await Shell.run(
            "/usr/bin/nettop", ["-L", "1", "-n", "-p", String(masterPID), "-J", "bytes_in,bytes_out"],
            timeout: 5)
        guard result.ok else { return [] }
        return parse(result.stdout)
    }

    /// Connection rows look like `tcp4 127.0.0.1:3000<->127.0.0.1:50123,120,340,`.
    /// Listening sockets have `*:*` or `*.*` as the far end and are skipped.
    static func parse(_ output: String) -> Set<Int> {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("tcp") {
            guard let name = line.split(separator: ",").first,
                  let arrow = name.range(of: "<->") else { continue }
            let far = name[arrow.upperBound...]
            guard far != "*:*", far != "*.*" else { continue }
            let near = name[..<arrow.lowerBound]
            guard let space = near.lastIndex(of: " ") else { continue }
            let address = near[near.index(after: space)...]
            guard address.hasPrefix("127.0.0.1"),
                  let sep = address.lastIndex(where: { $0 == ":" || $0 == "." }),
                  let port = Int(address[address.index(after: sep)...]) else { continue }
            ports.insert(port)
        }
        return ports
    }
}
