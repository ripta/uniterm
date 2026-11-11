import AppletKit
import Foundation

/// The text the Pending Requests panel shows for a launch or a launch grant.
///
/// A declaration can come from a program, so its arguments and values are shown escaped. Each
/// argument and each value gets a line of its own. A control character, a bidi override or
/// isolate, or a directional mark shows as its escape, so no input can start a new line or
/// reorder what the user reads before allowing it.
enum LaunchApprovalText {
  static func request(_ launch: ExecLaunch, pane: String) -> String {
    var lines = ["Run:"]

    for (index, argument) in launch.arguments.enumerated() {
      lines.append("  argv[\(index)] \(argument.isEmpty ? "(empty)" : escaped(argument))")
    }

    lines.append("Directory: \(escaped(launch.directory))")

    if launch.environment.isEmpty {
      lines.append("Environment: none")
    } else {
      lines.append("Environment:")

      for (key, value) in launch.environment.sorted(by: { $0.key < $1.key }) {
        lines.append("  \(key)=\(escaped(value))")
      }
    }

    lines.append("Pane: \(escaped(pane))")

    return lines.joined(separator: "\n")
  }

  static func grant(_ grant: ExecLaunchAuthority.Grant, pane: String) -> String {
    let keys = grant.environmentKeys.sorted().joined(separator: ", ")

    return [
      "Program: \(escaped(grant.executable)), with any arguments",
      "Directory: \(escaped(grant.directory))",
      "Environment keys: \(keys.isEmpty ? "none" : keys), with any values",
      "Pane: \(escaped(pane))",
    ].joined(separator: "\n")
  }

  /// The text with each scalar that could fake a line or reorder text written as an escape, and
  /// each backslash doubled, so an escape in the input reads apart from one written here.
  static func escaped(_ text: String) -> String {
    var result = ""

    for scalar in text.unicodeScalars {
      switch scalar {
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      default:
        if isUnsafe(scalar) {
          result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }

    return result
  }

  /// C0 and C1 controls, DEL, the line and paragraph separators, directional marks, and the
  /// bidi embeddings, overrides, and isolates.
  private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069,
      0x061C:
      return true
    default:
      return false
    }
  }
}
