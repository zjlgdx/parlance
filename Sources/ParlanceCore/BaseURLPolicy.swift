import Foundation

/// Why a base URL is rejected. Diagnostics name the violated rule, never the URL itself.
public enum BaseURLViolation: Sendable, Equatable {
  case unsupportedScheme, missingHost, userInformation, query, fragment
}

/// Base URL rules shared by the CLI and the App settings form (CLI and core design §7).
public enum BaseURLPolicy {
  public static func violation(of url: URL) -> BaseURLViolation? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return .unsupportedScheme
    }
    guard let host = url.host(percentEncoded: false), !host.isEmpty else { return .missingHost }
    if url.user() != nil || url.password() != nil { return .userInformation }
    if url.query() != nil { return .query }
    if url.fragment() != nil { return .fragment }
    return nil
  }

  /// `localhost`, `127.0.0.0/8` as a dotted quad, or `::1`.
  public static func isLoopback(_ url: URL) -> Bool {
    guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
    if host == "localhost" || host == "::1" { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, parts.first == "127" else { return false }
    return parts.allSatisfy { part in
      guard let value = UInt8(part) else { return false }
      return String(value) == part
    }
  }

  /// An API key may travel over https, or over http only to a loopback address.
  public static func allowsKey(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased()
    return scheme == "https" || (scheme == "http" && isLoopback(url))
  }
}
