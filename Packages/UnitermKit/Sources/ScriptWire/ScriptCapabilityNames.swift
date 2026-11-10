/// The Janet sandbox capabilities that `--allow` can grant a script or a REPL. The default sandbox
/// denies each one. The app shows these names when the user restarts a REPL with capabilities, and
/// the helper checks every name it is given against Janet's own table.
public enum ScriptCapabilityNames {
  public static let grantable = [
    "chroot", "env", "ffi", "ffi-define", "ffi-jit", "ffi-use", "fs", "fs-read", "fs-temp",
    "fs-write", "modules", "net", "net-connect", "net-listen", "sandbox", "signal", "subprocess",
    "threads",
  ]
}
