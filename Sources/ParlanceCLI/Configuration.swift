import ArgumentParser
import Foundation
import ParlanceCore
import TOMLDecoder

func cliFail(_ code: Int32, _ message: String, _ environment: CLIEnvironment) throws -> Never {
  environment.stderr("pl: \(TerminalText.display(message))\n")
  throw ExitCode(code)
}

func safeConfigValue(_ value: String) -> String {
  TerminalText.display(Redactor.redact(value).text)
}

struct CLIConfiguration: Decodable {
  struct Provider: Decodable {
    enum CodingKeys: String, CodingKey {
      case model
      case baseURL = "base_url"
      case apiKeyCommand = "api_key_cmd"
    }
    var model: String?
    var baseURL: String?
    var apiKeyCommand: String?
  }
  struct Model: Decodable {
    enum CodingKeys: String, CodingKey {
      case effort, thinking
      case firstTextTimeout = "first_text_timeout"
      case extraBody = "extra_body"
      case maxOutputField = "max_output_field"
      case systemRole = "system_role"
    }
    var effort: JSONValue?
    var thinking: JSONValue?
    var firstTextTimeout: JSONValue?
    var extraBody: [String: JSONValue]?
    var maxOutputField: String?
    var systemRole: String?

    func override(path: String, environment: CLIEnvironment) throws -> ModelOverride {
      if let field = maxOutputField, MaxOutputField(rawValue: field) == nil {
        try cliFail(78, "invalid field \(path).max_output_field. Check config.toml.", environment)
      }
      if let role = systemRole, SystemRole(rawValue: role) == nil {
        try cliFail(78, "invalid field \(path).system_role. Check config.toml.", environment)
      }
      let result = ModelOverride(
        extraBody: extraBody, maxOutputField: maxOutputField.flatMap(MaxOutputField.init),
        systemRole: systemRole.flatMap(SystemRole.init))
      do { try result.validate() } catch {
        try cliFail(
          78, "reserved field in \(path).extra_body. Remove reserved request fields.", environment)
      }
      return result
    }
  }
  enum CodingKeys: String, CodingKey {
    case provider, tone, fixes, providers, models, effort, thinking
    case firstTextTimeout = "first_text_timeout"
    case targetLanguage = "target_language"
    case nativeLanguage = "native_language"
  }
  var effort: JSONValue?
  var thinking: JSONValue?
  var firstTextTimeout: JSONValue?
  var provider: String?
  var targetLanguage: String?
  var nativeLanguage: String?
  var tone: String?
  var fixes: Bool?
  var providers: [String: Provider]?
  var models: [String: Model]?

  static func path(_ environment: CLIEnvironment) -> String {
    let xdg = environment.variables["XDG_CONFIG_HOME"]
    let directory =
      xdg.flatMap { $0.hasPrefix("/") ? $0 : nil }
      ?? (environment.homeDirectory + "/.config")
    return URL(fileURLWithPath: directory).appendingPathComponent("parlance/config.toml").path
  }

  static func load(_ environment: CLIEnvironment) throws -> Self {
    let data: Data?
    do { data = try environment.readConfig(path(environment)) } catch {
      try cliFail(78, "could not read config.toml. Check file permissions.", environment)
    }
    guard let data else { return Self() }
    let table: TOMLTable
    do {
      table = try TOMLTable(source: data)
      // Scalar conversion is lazy; force it so malformed values in unknown fields are syntax errors too.
      _ = try [String: Any](table)
    } catch {
      // 0.4.x exposes no source position API or columns. Only extract its leading line marker;
      // never forward the description (it can contain the original key or value).
      let description = String(describing: error)
      let regex = try! NSRegularExpression(pattern: #"^\(Line ([0-9]+)\)"#)
      let range = NSRange(description.startIndex..., in: description)
      let line =
        regex.firstMatch(in: description, range: range).flatMap {
          Range($0.range(at: 1), in: description).map { String(description[$0]) }
        }
      try cliFail(
        78,
        "config.toml has a syntax error\(line.map { " at line \($0)" } ?? ""). Check the TOML syntax.",
        environment)
    }
    try inspect(table, path: [], extraBody: false, environment: environment)
    // TOMLDecoder 0.4.x has no public decode-from-table API. Project the already parsed table
    // onto the known schema, then use Decodable; unknown fields never enter type diagnostics.
    let object = try project(table, path: [], environment: environment)
    let result: Self
    do {
      let json = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
      result = try JSONDecoder().decode(Self.self, from: json)
    } catch let error as DecodingError {
      let context: DecodingError.Context
      switch error {
      case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): context = c
      case .keyNotFound(_, let c): context = c
      @unknown default:
        try cliFail(
          78, "invalid config.toml type. Check the known configuration fields.", environment)
      }
      let path = diagnosticPath(context.codingPath.map(\.stringValue))
      try cliFail(78, "invalid type at \(path). Check config.toml.", environment)
    } catch {
      try cliFail(
        78, "invalid config.toml type. Check the known configuration fields.", environment)
    }
    if let provider = result.provider, ProviderPreset.named(provider) == nil {
      try cliFail(
        78, "invalid field provider. Choose a supported preset in config.toml.", environment)
    }
    if let tone = result.tone, RewriteSettings.Tone(rawValue: tone) == nil {
      try cliFail(78, "invalid field tone. Choose agent or casual in config.toml.", environment)
    }
    for (id, entry) in result.providers ?? [:] {
      _ = try baseURL(for: ProviderPreset.named(id)!, entry: entry, environment: environment)
    }
    for (id, entry) in result.models ?? [:] {
      _ = try entry.override(path: diagnosticPath(["models", id]), environment: environment)
    }
    return result
  }

  static func baseURL(for preset: ProviderPreset, entry: Provider?, environment: CLIEnvironment)
    throws -> URL?
  {
    guard let value = entry?.baseURL else { return preset.baseURL }
    let path = "providers.\(preset.id).base_url"
    guard let url = URL(string: value) else {
      try cliFail(78, "\(path) is not a valid URL. Use http or https with a host.", environment)
    }
    if let violation = BaseURLPolicy.violation(of: url) {
      let rule: String
      switch violation {
      case .unsupportedScheme: rule = "must use http or https"
      case .missingHost: rule = "must have a host"
      case .userInformation: rule = "must not contain user information"
      case .query: rule = "must not contain a query string"
      case .fragment: rule = "must not contain a fragment"
      }
      try cliFail(78, "\(path) \(rule). Check config.toml.", environment)
    }
    return url
  }

  func selectProvider(_ option: String?, environment: CLIEnvironment) throws -> ProviderPreset {
    if let id = option ?? provider {
      guard let preset = ProviderPreset.named(id) else {
        try cliFail(
          option == nil ? 78 : 64, "unknown provider. Choose a supported --provider ID.",
          environment)
      }
      return preset
    }
    let candidates = ProviderPreset.all.filter {
      $0.id != "compatible"
        && KeySources.hasEnvironmentKey(environment.variables[$0.apiKeyEnvironmentVariable])
    }
    guard candidates.count == 1 else {
      try cliFail(
        78,
        "could not determine a provider. Set provider in config.toml, choose --provider, or set exactly one official provider API key variable.",
        environment)
    }
    return candidates[0]
  }

  func resolve(
    _ option: String?, model: String?, reasoning: ReasoningOptions? = nil,
    environment: CLIEnvironment
  ) throws
    -> ResolvedProvider
  {
    try reasoning?.validateValues(environment: environment)
    let preset = try selectProvider(option, environment: environment)
    let entry = providers?[preset.id]
    guard let base = try Self.baseURL(for: preset, entry: entry, environment: environment) else {
      try cliFail(78, "missing providers.compatible.base_url. Set it in config.toml.", environment)
    }
    guard let model = model ?? entry?.model ?? preset.defaultModel, !model.isEmpty else {
      try cliFail(
        78, "missing providers.\(preset.id).model. Set it in config.toml or use --model.",
        environment)
    }
    let override = try models?[model]?.override(
      path: Self.diagnosticPath(["models", model]), environment: environment)
    var resolved = ResolvedProvider(preset: preset, baseURL: base, model: model, override: override)
    try applyReasoning(to: &resolved, options: reasoning, environment: environment)
    return resolved
  }

  private static let rootFields: Set<String> = [
    "provider", "target_language", "native_language", "tone", "fixes", "providers", "models",
    "effort", "thinking", "first_text_timeout",
  ]
  private static let providerFields: Set<String> = ["model", "base_url", "api_key_cmd"]
  private static let modelFields: Set<String> = [
    "extra_body", "max_output_field", "system_role", "effort", "thinking", "first_text_timeout",
  ]

  private static func knownFields(_ path: [String]) -> Set<String>? {
    if path.isEmpty { return rootFields }
    if path == ["providers"] { return Set(ProviderPreset.all.map(\.id)) }
    if path.count == 2 && path[0] == "providers" && ProviderPreset.named(path[1]) != nil {
      return providerFields
    }
    if path.count == 2 && path[0] == "models" { return modelFields }
    return nil
  }

  /// Names only what the schema owns: the path stops before the first segment that is not a known
  /// field of its table (an unknown name may itself be a credential) and after `extra_body`.
  static func diagnosticPath(_ path: [String]) -> String {
    var result: [String] = []
    for (index, part) in path.enumerated() {
      if index == 1 && path.first == "models" {
        result.append("\"\(safeConfigValue(part))\"")
      } else if let known = knownFields(Array(path[..<index])), known.contains(part) {
        result.append(part)
      } else {
        break
      }
      if part == "extra_body" && index == 2 { break }
    }
    return result.isEmpty ? "config.toml" : result.joined(separator: ".")
  }

  static func forbidden(_ name: String) -> Bool {
    let chars = Array(name)
    var normalized = ""
    for index in chars.indices {
      let c = chars[index]
      if index > 0 && c.isASCII && c.isUppercase {
        let prev = chars[index - 1]
        let lowerBoundary = prev.isLowercase || prev.isNumber
        let nextLower = index + 1 < chars.count && chars[index + 1].isLowercase
        let plural =
          nextLower && chars[index + 1] == "s"
          && (index + 2 == chars.count || !chars[index + 2].isLetter)
        if lowerBoundary || (prev.isUppercase && nextLower && !plural) { normalized += "_" }
      }
      normalized += "-. ".contains(c) ? "_" : String(c).lowercased()
    }
    let words = normalized.split(separator: "_").map(String.init)
    let banned: Set<String> = [
      "secret", "secrets", "password", "passwd", "passphrase", "credential", "credentials",
      "authorization", "auth", "bearer", "apikey", "pwd", "pass", "cookie", "key", "keys",
    ]
    for (index, word) in words.enumerated() {
      if banned.contains(word) { return true }
      if word == "token" && (index + 1 == words.count || !["id", "ids"].contains(words[index + 1]))
      {
        return true
      }
    }
    let joined = words.joined()
    return [
      "secret", "passw", "passphrase", "credential", "apikey", "apitoken", "accesstoken",
      "authtoken", "privatekey", "bearer",
    ].contains { joined.contains($0) }
  }

  /// Only schema-owned names survive: model IDs, unknown names and array indices are never shown.
  private static func safeTableLabel(_ path: [String]) -> String {
    if path.first == "models" {
      return path.count >= 3 && path[2] == "extra_body" ? "models.extra_body" : "models"
    }
    if path.first == "providers" {
      if path.count >= 2, ProviderPreset.named(path[1]) != nil { return "providers.\(path[1])" }
      return "providers"
    }
    return "root"
  }

  private static func inspect(
    _ table: TOMLTable, path: [String], extraBody: Bool, environment: CLIEnvironment
  ) throws {
    if let known = knownFields(path) {
      let count = table.keys.filter { !known.contains($0) }.count
      if count > 0 {
        let label = safeTableLabel(path)
        environment.stderr("pl: \(label) contains \(count) unknown field(s); ignored.\n")
      }
    }
    for key in table.keys {
      let modelID = path == ["models"]
      let command = path.count == 2 && path[0] == "providers" && key == "api_key_cmd"
      if !modelID && !command && !(extraBody && key == "prompt_cache_key") && forbidden(key) {
        try cliFail(
          78,
          "credential-shaped field in config.toml table \(safeTableLabel(path)). Use environment variables, pl auth set or api_key_cmd.",
          environment)
      }
      let childPath = path + [key]
      let inExtra = extraBody || (path.count == 2 && path[0] == "models" && key == "extra_body")
      if let child = try? table.table(forKey: key) {
        try inspect(child, path: childPath, extraBody: inExtra, environment: environment)
      } else if let array = try? table.array(forKey: key) {
        try inspect(array, path: childPath, extraBody: inExtra, environment: environment)
      }
    }
  }

  private static func inspect(
    _ array: TOMLArray, path: [String], extraBody: Bool, environment: CLIEnvironment
  ) throws {
    for index in 0..<array.count {
      if let table = try? array.table(atIndex: index) {
        try inspect(table, path: path + ["[]"], extraBody: extraBody, environment: environment)
      } else if let nested = try? array.array(atIndex: index) {
        try inspect(nested, path: path + ["[]"], extraBody: extraBody, environment: environment)
      }
    }
  }

  private static func project(_ table: TOMLTable, path: [String], environment: CLIEnvironment)
    throws -> [String: Any]
  {
    let known = knownFields(path)
    var result: [String: Any] = [:]
    for key in table.keys where known == nil || known!.contains(key) {
      let next = path + [key]
      if let child = try? table.table(forKey: key) {
        result[key] = try project(child, path: next, environment: environment)
      } else {
        // Convert only this field so conversion errors cannot expose unknown names or values.
        let value: Any
        if let string = try? table.string(forKey: key) {
          value = string
        } else if let bool = try? table.bool(forKey: key) {
          value = bool
        } else if let integer = try? table.integer(forKey: key) {
          value = integer
        } else if let float = try? table.float(forKey: key), float.isFinite {
          // Keep a TOML float invalid for this integer-only field, even if JSON would
          // decode it as Int. Defer rejection until the selected model uses this value.
          value =
            key == "first_text_timeout"
              && (path.isEmpty || (path.count == 2 && path[0] == "models")) ? [Any]() : float
        } else if let array = try? table.array(forKey: key) {
          do { value = try [Any](array) } catch {
            try cliFail(
              78, "invalid type at \(diagnosticPath(next)). Check config.toml.", environment)
          }
        } else {
          try cliFail(
            78, "invalid type at \(diagnosticPath(next)). Check config.toml.", environment)
        }
        guard JSONSerialization.isValidJSONObject([value]) else {
          try cliFail(
            78, "invalid type at \(diagnosticPath(next)). Check config.toml.", environment)
        }
        result[key] = value
      }
    }
    return result
  }
}
