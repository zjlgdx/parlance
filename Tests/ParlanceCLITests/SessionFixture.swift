import Foundation
import ParlanceCore
import Testing

@testable import ParlanceCLI

/// All session records are synthetic and live below a disposable home.
struct SessionFixture {
  let home: URL
  let cwd = "/fictional/project"

  init() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: home) }

  @discardableResult
  func claude(_ records: [[String: Any]], id: String = "aaaaaaaa-1111", tail: String = "") throws
    -> URL
  {
    let directory = home.appendingPathComponent(".claude/projects/-fictional-project")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(id + ".jsonl")
    let data =
      try records.map { record in
        var record = record
        record["cwd"] = record["cwd"] ?? cwd
        record["version"] = record["version"] ?? "2.1.318"
        record["timestamp"] = record["timestamp"] ?? "2026-11-05T14:02:00Z"
        return String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
      }.joined(separator: "\n") + "\n" + tail
    try Data(data.utf8).write(to: file)
    return file
  }

  static func user(_ text: String, id: String) -> [String: Any] {
    ["type": "user", "uuid": id, "message": ["content": text]]
  }

  static func assistant(_ text: String, id: String, stop: String = "end_turn") -> [String: Any] {
    [
      "type": "assistant", "uuid": id,
      "message": [
        "id": id, "content": [["type": "text", "text": text]], "stop_reason": stop,
      ],
    ]
  }
}

extension SessionFixture {
  var environment: CLIEnvironment {
    CLIEnvironment(
      variables: [:], stdinIsTTY: false, stdoutIsTTY: false, stderrIsTTY: false,
      readStdin: { Data() }, stdout: { _ in }, stderr: { _ in },
      makeProvider: { _ in MockProvider(scripts: []) }, homeDirectory: home.path,
      currentDirectory: cwd)
  }

  @discardableResult
  func codex(
    _ records: [[String: Any]], id: String = "bbbbbbbb-2222", mode: String = "paginated",
    cwd: String? = nil, root: URL? = nil, source: Any = "cli", tail: String = ""
  ) throws -> URL {
    let directory = (root ?? home.appendingPathComponent(".codex"))
      .appendingPathComponent("sessions/2026/11/05")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let metadata = Self.codexRecord(
      "session_meta",
      [
        "id": id, "cwd": cwd ?? self.cwd, "cli_version": "0.166.0", "history_mode": mode,
        "timestamp": "2026-11-05T14:02:00.123Z", "source": source,
      ])
    let text =
      try ([metadata] + records).map {
        String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
      }.joined(separator: "\n") + "\n" + tail
    let file = directory.appendingPathComponent("rollout-synthetic-" + id + ".jsonl")
    try Data(text.utf8).write(to: file)
    return file
  }

  static func codexRecord(_ type: String, _ payload: [String: Any]) -> [String: Any] {
    ["timestamp": "2026-11-05T14:02:00Z", "type": type, "payload": payload]
  }

  static func codexUser(_ text: String) -> [String: Any] {
    codexRecord(
      "response_item",
      [
        "type": "message", "role": "user", "content": [["type": "input_text", "text": text]],
      ])
  }

  static func complete(_ id: String, _ reply: String?) -> [String: Any] {
    codexRecord(
      "event_msg",
      [
        "type": "task_complete", "turn_id": id, "last_agent_message": reply as Any? ?? NSNull(),
      ])
  }
}
