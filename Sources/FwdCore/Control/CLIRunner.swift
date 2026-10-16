import Foundation

/// The command's request loop: ask the app, and if it isn't running, start
/// it once and keep asking while it comes up.
public enum CLIRunner {
    public static func send(_ request: ControlRequest, socket: String, launch: () -> Void,
                            attempts: Int = 50, delay: TimeInterval = 0.2) -> ControlReply {
        // Long enough for the slowest command, plus room to answer.
        let timeout = (request.timeout ?? 60) + 10
        var launched = false
        for _ in 0..<max(attempts, 1) {
            do {
                return try ControlClient.send(request, to: socket, timeout: timeout)
            } catch is ControlClient.Unreachable {
                if !launched {
                    launch()
                    launched = true
                }
                Thread.sleep(forTimeInterval: delay)
            } catch let error as ControlError {
                return .failure(error)
            } catch {
                return .failure(ControlError(.unreachable, "the fwd app gave an answer this command can't read; update fwd"))
            }
        }
        return .failure(ControlError(.unreachable, "couldn't reach the fwd app; is it installed? (open -a fwd)"))
    }
}
