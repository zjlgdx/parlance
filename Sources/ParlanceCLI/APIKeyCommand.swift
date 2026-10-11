import Darwin
import Foundation
import os

public struct APIKeyCommandResult: Sendable {
  public enum Termination: Sendable, Equatable {
    case exit(Int32)
    case signal(Int32)
    case timeout, launchFailed
  }
  public var termination: Termination
  /// At most `APIKeyCommand.stdoutLimit` bytes; anything beyond is drained and dropped.
  public var stdout: Data
  public var stdoutOverflowed: Bool

  public init(termination: Termination, stdout: Data = Data(), stdoutOverflowed: Bool = false) {
    self.termination = termination
    self.stdout = stdout
    self.stdoutOverflowed = stdoutOverflowed
  }
}

/// The helper retains the caller's session and foreground process group, so /dev/tty still works.
/// Nonblocking capture sources keep a full pipe from deadlocking the helper. Completion closes the
/// captures even if a background descendant inherited them; no output is written to disk. stderr is
/// drained and dropped (it is never shown) and stdout is kept only up to `stdoutLimit`, so a noisy
/// helper cannot grow memory without bound.
/// Known limit: timeout kills only /bin/sh. A helper it started may outlive pl; it deliberately
/// stays in pl's foreground process group so tools that prompt via /dev/tty keep working.
enum APIKeyCommand {
  static let stdoutLimit = 64 * 1024

  private struct Capture: Sendable {
    var stdout = Data()
    var stdoutOverflowed = false
    var timedOut = false
    var stdoutClosed = false
    var stderrClosed = false

    mutating func keep(_ data: Data) {
      let room = APIKeyCommand.stdoutLimit - stdout.count
      if data.count > room { stdoutOverflowed = true }
      stdout.append(data.prefix(max(room, 0)))
    }
  }

  static func run(_ command: String, timeout: TimeInterval, environment: [String: String]) async
    -> APIKeyCommandResult
  {
    var output: [Int32] = [0, 0]
    var error: [Int32] = [0, 0]
    guard pipe(&output) == 0 else { return .init(termination: .launchFailed) }
    guard pipe(&error) == 0 else {
      for fd in output { close(fd) }
      return .init(termination: .launchFailed)
    }
    let input = open("/dev/null", O_RDONLY)
    guard input >= 0 else {
      for fd in output + error { close(fd) }
      return .init(termination: .launchFailed)
    }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, error[1], STDERR_FILENO)
    for fd in [input] + output + error { posix_spawn_file_actions_addclose(&actions, fd) }
    let strings = ["/bin/sh", "-c", command].map { strdup($0)! }
    let envStrings = environment.map { strdup("\($0.key)=\($0.value)")! }
    defer { for pointer in strings + envStrings { free(pointer) } }
    var argv: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { $0 } + [nil]
    // Swift executor threads may block signals. Do not pass that thread-local mask to a helper:
    // it must still receive SIGINT from the terminal and termination signals sent to it.
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
      for fd in [input] + output + error { close(fd) }
      return .init(termination: .launchFailed)
    }
    defer { posix_spawnattr_destroy(&attributes) }
    var mask = sigset_t()
    sigemptyset(&mask)
    guard posix_spawnattr_setsigmask(&attributes, &mask) == 0,
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK)) == 0
    else {
      for fd in [input] + output + error { close(fd) }
      return .init(termination: .launchFailed)
    }
    var pid: pid_t = 0
    let code = posix_spawn(&pid, "/bin/sh", &actions, &attributes, &argv, &envp)
    for fd in [input, output[1], error[1]] { close(fd) }
    guard code == 0 else {
      for fd in [output[0], error[0]] { close(fd) }
      return .init(termination: .launchFailed)
    }
    let child = pid
    let outFD = output[0]
    let errFD = error[0]
    for fd in [outFD, errFD] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
    let queue = DispatchQueue(label: "parlance.api-key-command")
    let state = OSAllocatedUnfairLock(initialState: Capture())
    let outSource = DispatchSource.makeReadSource(fileDescriptor: outFD, queue: queue)
    let errSource = DispatchSource.makeReadSource(fileDescriptor: errFD, queue: queue)
    outSource.setEventHandler {
      let ended = state.withLock {
        let batch = drain(outFD)
        $0.keep(batch.data)
        $0.stdoutClosed = batch.ended
        return batch.ended
      }
      if ended { outSource.cancel() }
    }
    errSource.setEventHandler {
      let ended = state.withLock {
        let batch = drain(errFD)
        $0.stderrClosed = batch.ended
        return batch.ended
      }
      if ended { errSource.cancel() }
    }
    outSource.setCancelHandler { close(outFD) }
    errSource.setCancelHandler { close(errFD) }
    outSource.resume()
    errSource.resume()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler {
      state.withLock { $0.timedOut = true }
      kill(child, SIGKILL)
    }
    timer.resume()
    return await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        // Observe exit without reaping yet. Keeping the PID reserved until the serial queue
        // cancels its timer prevents a deadline racing with PID reuse.
        var info = siginfo_t()
        var waited: Int32
        repeat {
          waited = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT)
        } while waited == -1 && errno == EINTR
        let waitFailed = waited == -1
        queue.async {
          timer.cancel()
          var exitStatus: Int32 = 0
          while waitpid(child, &exitStatus, 0) == -1 && errno == EINTR {}
          let capture = state.withLock {
            if !$0.stdoutClosed { $0.keep(drain(outFD).data) }
            if !$0.stderrClosed { _ = drain(errFD) }
            return $0
          }
          outSource.cancel()
          errSource.cancel()
          let signal = exitStatus & 0x7f
          let termination: APIKeyCommandResult.Termination =
            capture.timedOut
            ? .timeout
            : (waitFailed
              ? .launchFailed : (signal == 0 ? .exit((exitStatus >> 8) & 0xff) : .signal(signal)))
          continuation.resume(
            returning: .init(
              termination: termination, stdout: capture.stdout,
              stdoutOverflowed: capture.stdoutOverflowed))
        }
      }
    }
  }

  private static func drain(_ descriptor: Int32) -> (data: Data, ended: Bool) {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    // Yield between batches so a continuously writing child cannot starve the deadline.
    for _ in 0..<16 {
      let count = read(descriptor, &buffer, buffer.count)
      if count > 0 {
        result.append(contentsOf: buffer.prefix(count))
      } else if count == -1 && errno == EINTR {
        continue
      } else {
        return (result, count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK))
      }
    }
    return (result, false)
  }
}
