import Foundation

public struct SessionFileStatus: Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public let size: UInt64

  public init(device: UInt64, inode: UInt64, size: UInt64) {
    self.device = device
    self.inode = inode
    self.size = size
  }

  func sameFile(as other: Self) -> Bool { device == other.device && inode == other.inode }

  static func read(_ path: String) throws -> Self {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let device = attributes[.systemNumber] as? NSNumber,
      let inode = attributes[.systemFileNumber] as? NSNumber,
      let size = attributes[.size] as? NSNumber
    else { throw CocoaError(.fileReadUnknown) }
    return Self(device: device.uint64Value, inode: inode.uint64Value, size: size.uint64Value)
  }
}

/// Keeps the parser and the last complete-line offset for one bound file.
struct SessionWatchFile {
  let path: String
  let identity: SessionFileStatus
  var parser: any SessionParsing
  private(set) var offset: UInt64 = 0
  private var observedSize: UInt64 = 0

  init(binding: SessionInput.Binding, environment: CLIEnvironment) throws {
    path = binding.session.path
    identity = try environment.sessionFileStatus(path)
    parser = binding.source.makeParser()
  }

  mutating func read(environment: CLIEnvironment) throws {
    let status = try environment.sessionFileStatus(path)
    guard identity.sameFile(as: status), status.size >= observedSize else {
      throw CocoaError(.fileReadUnknown)
    }
    guard status.size > observedSize else { return }
    var pending = Data()
    var position = offset
    while position < status.size {
      try autoreleasepool {
        let count = Int(min(64 * 1024, status.size - position))
        let chunk = try environment.readSessionBytes(path, position, count)
        guard !chunk.isEmpty, chunk.count <= count else { throw CocoaError(.fileReadUnknown) }
        position += UInt64(chunk.count)
        var start = chunk.startIndex
        for end in chunk.indices where chunk[end] == 10 {
          pending.append(chunk[start..<end])
          parser.feed(pending)
          offset += UInt64(pending.count + 1)
          pending.removeAll(keepingCapacity: false)
          start = end + 1
        }
        pending.append(chunk[start...])
      }
    }
    // Check again before publishing replies, including replacement during the offset read.
    let after = try environment.sessionFileStatus(path)
    guard identity.sameFile(as: after), after.size >= status.size else {
      throw CocoaError(.fileReadUnknown)
    }
    observedSize = status.size
  }
}
