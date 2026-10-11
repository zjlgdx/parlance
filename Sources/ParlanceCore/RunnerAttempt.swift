/// Shared provider-event handling for rewrite, structured explanation and plain follow-up.
struct RunnerAttempt: Sendable {
  let snapshot: SectionsSnapshot
  let eligibility: Eligibility
  let usage: LLMUsage?

  static func run(
    request: LLMRequest, schema: SectionSchema?, provider: any LLMProvider,
    cancellation: LLMCancellation,
    sections: @Sendable (SectionsSnapshot) -> Void,
    retrying: @Sendable (Duration, LLMErrorCode) -> Void
  ) async -> RunnerAttempt {
    var parser = SectionStreamParser(schema: schema ?? SectionSchema(tags: []))
    var usage: LLMUsage?
    var finish: LLMFinishReason?
    var failure: LLMError?
    do {
      for try await event in provider.stream(request, cancellation: cancellation) {
        switch event {
        case .text(let text):
          parser.feed(text)
          sections(parser.snapshot)
        case .retrying(let after, let cause): retrying(after, cause)
        case .usage(let value): usage = value
        case .finished(let reason): finish = reason
        }
      }
    } catch {
      failure = error as? LLMError ?? (Task.isCancelled ? .aborted : .transport)
    }
    // Explicit cancellation wins over a provider's error, quiet end or finished event.
    if cancellation.isCancelled || Task.isCancelled { failure = .aborted }
    let snapshot = parser.finish()
    let eligibility: Eligibility
    if let failure {
      eligibility = .incomplete(.error(failure))
    } else {
      switch finish {
      case .stop: eligibility = snapshot.isMalformed ? .malformed : .eligible
      case .length: eligibility = .incomplete(.length)
      case .contentFilter: eligibility = .incomplete(.contentFilter)
      case .other: eligibility = .incomplete(.other)
      case nil:
        eligibility = .incomplete(.error(snapshot.rawText.isEmpty ? .emptyResponse : .transport))
      }
    }
    return RunnerAttempt(snapshot: snapshot, eligibility: eligibility, usage: usage)
  }
}
