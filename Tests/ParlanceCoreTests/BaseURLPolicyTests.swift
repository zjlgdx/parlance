import Foundation
import Testing

@testable import ParlanceCore

struct BaseURLPolicyTests {
  @Test func violations() throws {
    let cases: [(String, BaseURLViolation?)] = [
      ("https://api.example.com/v1", nil), ("http://localhost:11434/v1", nil),
      ("HTTPS://api.example.com", nil), ("ftp://api.example.com/v1", .unsupportedScheme),
      ("file:///v1", .unsupportedScheme), ("http:///v1", .missingHost),
      ("https://user@api.example.com/v1", .userInformation),
      ("https://user:fake-secret@api.example.com/v1", .userInformation),
      ("https://api.example.com/v1?key=fake", .query),
      ("https://api.example.com/v1#frag", .fragment),
    ]
    for (text, expected) in cases {
      let url = try #require(URL(string: text))
      #expect(BaseURLPolicy.violation(of: url) == expected, "\(text)")
    }
  }

  @Test func loopbackAndKeyTransport() throws {
    let loopback = [
      "http://localhost/v1", "http://LOCALHOST:11434", "http://127.0.0.1/v1",
      "http://127.255.0.7/v1", "http://[::1]:8080/v1",
    ]
    let remote = [
      "http://gateway.example/v1", "http://127.1/v1", "http://127.0.0.01/v1",
      "http://128.0.0.1/v1", "http://[::ffff:127.0.0.1]/v1", "http://localhost.example/v1",
    ]
    for text in loopback {
      let url = try #require(URL(string: text))
      #expect(BaseURLPolicy.isLoopback(url), "\(text)")
      #expect(BaseURLPolicy.allowsKey(url), "\(text)")
    }
    for text in remote {
      let url = try #require(URL(string: text))
      #expect(!BaseURLPolicy.isLoopback(url), "\(text)")
      #expect(!BaseURLPolicy.allowsKey(url), "\(text)")
    }
    #expect(BaseURLPolicy.allowsKey(try #require(URL(string: "https://gateway.example/v1"))))
    for text in ["ftp://localhost/v1", "ws://127.0.0.1/v1"] {
      let url = try #require(URL(string: text))
      #expect(BaseURLPolicy.isLoopback(url), "\(text)")
      #expect(!BaseURLPolicy.allowsKey(url), "\(text)")
    }
  }
}
