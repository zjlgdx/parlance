import Foundation

/// Removes escape sequences before input validation. Display additionally filters C0/C1 controls.
enum TerminalText {
  static func stripEscapes(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var output = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
      guard scalars[index].value == 0x1B else {
        output.append(scalars[index])
        index += 1
        continue
      }
      index += 1
      guard index < scalars.count else { break }
      let introducer = scalars[index].value
      index += 1
      switch introducer {
      case 0x5B:  // CSI: parameters and intermediates end at a final byte.
        while index < scalars.count {
          let value = scalars[index].value
          index += 1
          if (0x40...0x7E).contains(value) { break }
        }
      case 0x5D, 0x50, 0x58, 0x5E, 0x5F:  // OSC, DCS, SOS, PM, APC.
        while index < scalars.count {
          let value = scalars[index].value
          index += 1
          if value == 0x9C || (introducer == 0x5D && value == 7) { break }
          if value == 0x1B && index < scalars.count && scalars[index].value == 0x5C {
            index += 1
            break
          }
        }
      case 0x20...0x2F:
        while index < scalars.count && (0x20...0x2F).contains(scalars[index].value) {
          index += 1
        }
        if index < scalars.count { index += 1 }
      default: break
      }
    }
    return String(output)
  }

  static func display(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        stripEscapes(text).unicodeScalars.filter {
          $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && !(0x7F...0x9F).contains($0.value))
        }))
  }
}
