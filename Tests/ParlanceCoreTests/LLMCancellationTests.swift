import Foundation
import Testing
import os

@testable import ParlanceCore

struct LLMCancellationTests {
  @Test(arguments: [false, true])
  func reentrant(alreadyCancelled: Bool) async throws {
    let token = LLMCancellation()
    let count = OSAllocatedUnfairLock(initialState: 0)
    if alreadyCancelled { token.cancel() }
    try await bounded {
      await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          token.onCancel {
            #expect(token.isCancelled)
            count.withLock { $0 += 1 }
            token.onCancel { count.withLock { $0 += 1 } }
          }
          token.cancel()
          token.cancel()
          continuation.resume()
        }
      }
    }
    #expect(count.withLock { $0 } == 2)
  }
}
