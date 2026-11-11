import Foundation

@testable import ParlanceCLI

extension SessionFixture {
  @discardableResult
  func pi(
    _ records: [[String: Any]], id: String = "cccccccc-3333", version: Any? = 3,
    cwd: String? = nil, root: URL? = nil, flatDirectory: URL? = nil, tail: String = ""
  ) throws -> URL {
    let directory =
      flatDirectory
      ?? (root ?? home.appendingPathComponent(".pi/agent"))
      .appendingPathComponent("sessions/--fictional-project--")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var header: [String: Any] = [
      "type": "session", "id": id, "cwd": cwd ?? self.cwd, "timestamp": "2026-11-05T14:02:00Z",
    ]
    if let version { header["version"] = version }
    let file = directory.appendingPathComponent("2026-11-05T14-02-00Z_" + id + ".jsonl")
    let data = try SessionWatchFixture.lines([header] + records) + Data(tail.utf8)
    try data.write(to: file)
    return file
  }

  static func piEntry(
    _ type: String, id: String, parent: String?, fields: [String: Any] = [:]
  ) -> [String: Any] {
    var entry = fields
    entry["type"] = type
    entry["id"] = id
    entry["parentId"] = parent as Any? ?? NSNull()
    entry["timestamp"] = "2026-11-05T14:02:00Z"
    return entry
  }

  static func piMessage(
    _ role: String, _ content: Any, id: String, parent: String?, stop: String = "stop"
  ) -> [String: Any] {
    var message: [String: Any] = [
      "role": role, "content": content, "timestamp": 1_793_887_320_000,
    ]
    if role == "assistant" {
      message["stopReason"] = stop
      message["api"] = "openai-responses"
      message["provider"] = "fictional-provider"
      message["model"] = "fictional-model"
    }
    return piEntry("message", id: id, parent: parent, fields: ["message": message])
  }

  static func piAssistant(
    _ text: String, id: String, parent: String?, stop: String = "stop"
  ) -> [String: Any] {
    piMessage("assistant", [["type": "text", "text": text]], id: id, parent: parent, stop: stop)
  }

  static func piEdit(
    _ target: String, content: Any?, id: String, parent: String?
  ) -> [String: Any] {
    piEntry(
      "context_edit", id: id, parent: parent,
      fields: [
        "targetId": target, "replacement": content.map { ["content": $0] } as Any? ?? NSNull(),
      ])
  }
}
