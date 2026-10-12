import Foundation
import Testing

@testable import ParlanceCLI

struct APIKeyCommandTests {
  @Test func realTimeoutIsBounded() async {
    let start = ContinuousClock.now
    let result = await APIKeyCommand.run("exec sleep 60", timeout: 0.2, environment: [:])
    #expect(result.termination == .timeout)
    #expect(start.duration(to: .now) < .seconds(10))
  }

  @Test func realExitAndSignal() async {
    for (command, expected) in [
      ("exit 7", APIKeyCommandResult.Termination.exit(7)),
      ("kill -TERM $$", .signal(15)),
    ] {
      let result = await APIKeyCommand.run(command, timeout: 30, environment: [:])
      #expect(result.termination == expected)
    }
  }

  @Test func realLargeOutputIsDrainedAndCapped() async {
    let result = await APIKeyCommand.run(
      #"head -c 200000 /dev/zero | tr '\0' a; head -c 200000 /dev/zero | tr '\0' b >&2"#,
      timeout: 30, environment: [:])
    #expect(result.termination == .exit(0))
    #expect(result.stdout == Data(repeating: 97, count: APIKeyCommand.stdoutLimit))
    #expect(result.stdoutOverflowed)
  }

  @Test func outputWithinTheLimitIsComplete() async {
    let result = await APIKeyCommand.run(
      #"head -c 65536 /dev/zero | tr '\0' a"#, timeout: 30, environment: [:])
    #expect(result.termination == .exit(0))
    #expect(result.stdout == Data(repeating: 97, count: 65536))
    #expect(!result.stdoutOverflowed)
  }

  @Test func realStdinIsNull() async {
    let result = await APIKeyCommand.run("read x || printf eof", timeout: 30, environment: [:])
    #expect(result.termination == .exit(0))
    #expect(result.stdout == Data("eof".utf8))
  }

  @Test func backgroundDescendantDoesNotHoldCaptureOpen() async throws {
    let pidFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("pl-descendant-\(UUID().uuidString).pid")
    defer {
      // APIKeyCommand leaves descendants running by design; stop the one this test started.
      if let text = try? String(contentsOf: pidFile, encoding: .utf8),
        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        kill(pid, SIGTERM)
      }
      try? FileManager.default.removeItem(at: pidFile)
    }
    let start = ContinuousClock.now
    // A held pipe would last until the timeout; the background sleep outlives both.
    let result = await APIKeyCommand.run(
      #"(sleep 60 & echo $! > "$PL_TEST_PID_FILE") ; printf k"#, timeout: 30,
      environment: ["PL_TEST_PID_FILE": pidFile.path])
    #expect(result.termination == .exit(0))
    #expect(result.stdout == Data("k".utf8))
    #expect(start.duration(to: .now) < .seconds(30))
  }
}
