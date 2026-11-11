import Foundation

/// The synthetic driver the exec tests run. Each mode is one behavior a driver can have, good or
/// bad, so a test names the one it proves.
public enum ExecTestDriver {
  public static let perl = "/usr/bin/perl"

  /// The driver script. Perl runs it with the arguments a test gives, and no shell reads them.
  public static var script: String {
    guard let url = Bundle.module.url(forResource: "Fixtures/driver", withExtension: "pl") else {
      preconditionFailure("the driver fixture is missing from the test bundle")
    }

    return url.path
  }

  /// The argv for one mode, for the applet type and schema version the driver says hello with.
  public static func arguments(
    _ mode: String, type: String, schema: Int = 1, _ rest: [String] = []
  ) -> [String] {
    [perl, script, mode, type, String(schema)] + rest
  }
}
