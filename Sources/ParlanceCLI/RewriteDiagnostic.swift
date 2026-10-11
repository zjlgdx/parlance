import ParlanceCore

struct RewriteDiagnostic {
  var code: String
  var exitCode: Int32
  var message: String
  var nextStep: String
  var httpStatus: Int?
  var providerCode: KnownProviderCode?

  static func forEligibility(_ eligibility: Eligibility) -> Self? {
    switch eligibility {
    case .eligible: return nil
    case .placeholdersChanged:
      return Self(
        code: "placeholders_changed", exitCode: 8,
        message: "the model changed identifiers, paths or flags.", nextStep: "Try again.")
    case .placeholdersUnavailable:
      return Self(
        code: "placeholders_unavailable", exitCode: 8,
        message: "no placeholder delimiters are free for this input.",
        nextStep: "Remove the bracket characters ⟦⟧ ⟪⟫ 〖〗 from the input.")
    case .malformed:
      return Self(
        code: "malformed_sections", exitCode: 8,
        message: "could not recognise sections in the model output.", nextStep: "Try again.")
    case .incomplete(let reason):
      switch reason {
      case .error(let error): return forError(error)
      case .length:
        return Self(
          code: "truncated", exitCode: 8,
          message: "the model output was truncated.", nextStep: "Try shorter input.")
      case .contentFilter:
        return Self(
          code: "content_filtered", exitCode: 8,
          message: "the model output was content filtered.", nextStep: "Revise the input.")
      case .other:
        return Self(
          code: "finish_other", exitCode: 8,
          message: "the model stopped for an unknown reason.", nextStep: "Try again.")
      }
    }
  }

  static func forError(_ error: LLMError) -> Self {
    var diagnostic = Self(
      code: error.code.rawValue, exitCode: 8, message: "", nextStep: "Try again.")
    switch error {
    case .auth(let status):
      diagnostic.exitCode = 3
      diagnostic.httpStatus = status
      diagnostic.message = "authentication failed."
      diagnostic.nextStep = "Check the provider API key."
    case .transport:
      diagnostic.exitCode = 4
      diagnostic.message = "a transport error interrupted the request."
      diagnostic.nextStep = "Check your connection and try again."
    case .timeout(let kind):
      diagnostic.exitCode = 4
      switch kind {
      case .firstToken:
        diagnostic.message = "no first token arrived before the timeout."
        diagnostic.nextStep = "Try a faster model with --model <id>."
      case .idle: diagnostic.message = "the stream exceeded the idle timeout."
      case .total: diagnostic.message = "the request exceeded the total timeout."
      }
    case .quota(let status):
      diagnostic.exitCode = 5
      diagnostic.httpStatus = status
      diagnostic.message = "the provider quota was exhausted."
      diagnostic.nextStep = "Check your provider balance."
    case .rateLimit:
      diagnostic.exitCode = 6
      diagnostic.message = "the provider rate limited the request."
      diagnostic.nextStep = "Wait and try again."
    case .server(let status):
      diagnostic.exitCode = 6
      diagnostic.httpStatus = status
      diagnostic.message = "the provider reported a server error."
    case .invalidRequest(let status, let providerCode):
      diagnostic.exitCode = 7
      diagnostic.httpStatus = status
      diagnostic.providerCode = providerCode
      diagnostic.message = "the provider rejected the request."
      diagnostic.nextStep = "Check the model with --model <id>."
    case .emptyResponse: diagnostic.message = "the provider returned no text."
    case .malformedResponse: diagnostic.message = "the provider returned a malformed response."
    case .aborted:
      diagnostic.exitCode = 130
      diagnostic.message = "the request was aborted."
    }
    return diagnostic
  }

  var line: String {
    var details = ""
    if let httpStatus { details += " HTTP \(httpStatus)." }
    if let providerCode { details += " \(providerCode.rawValue)." }
    return "pl: \(message)\(details) \(nextStep)\n"
  }
}
