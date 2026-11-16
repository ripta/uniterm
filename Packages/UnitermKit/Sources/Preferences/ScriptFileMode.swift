/// How uniterm treats a script file that declares nothing about its powers.
///
/// A file that declares its powers in a first `(declare-permissions ...)` form is reviewed in both
/// modes. Only the file that declares nothing differs.
public enum ScriptFileMode: String, Sendable, CaseIterable {
  /// An undeclared file is refused before any of its code runs.
  case strict

  /// An undeclared file runs after a review that lasts for that one run.
  case unsafe
}

extension SettingKey where Value == ScriptFileMode {
  /// A missing or unknown stored value reads as strict, so a value this version does not know
  /// never opens the more permissive mode.
  public static var scriptFileMode: SettingKey<ScriptFileMode> {
    SettingKey(name: "scriptFileMode", defaultValue: .strict)
  }
}
