import Darwin
import Foundation

/// Reads process information from the system without depending on ScriptHost or TerminalSurface.
/// Both modules use this to query process identity and ancestry through sysctl.
///
/// `proc_pidinfo` refuses a setuid-root process, such as the `/usr/bin/login` that libghostty
/// spawns, for a caller that is not root. `sysctl(KERN_PROC_PID)` reads it.
public enum ProcessInspection {
  /// The start time of the given process, in seconds since epoch. Returns nil when the process
  /// does not exist, has exited, or the system refuses the query.
  public static func startTime(of pid: pid_t) -> Int? {
    guard let info = record(of: pid) else { return nil }

    return Int(info.kp_proc.p_starttime.tv_sec)
  }

  /// The parent PID and start time of the given process. Returns nil when the process does not
  /// exist, has no parent, or the system refuses the query.
  public static func parent(of pid: pid_t) -> (pid: pid_t, started: Int)? {
    guard let info = record(of: pid) else { return nil }

    let parentPid = info.kp_eproc.e_ppid

    guard parentPid > 0 else { return nil }

    guard let started = startTime(of: parentPid) else { return nil }

    return (pid: parentPid, started: started)
  }

  /// True when a process with the given ID and start time is running.
  public static func isRunning(pid: pid_t, started: Int) -> Bool {
    guard let actual = startTime(of: pid) else { return false }

    return actual == started
  }

  /// The executable path of the given process. Returns nil when the process does not exist or the
  /// system refuses the query.
  public static func executablePath(of pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))

    guard length > 0 else { return nil }

    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }

  /// The kernel's record of a live process. For a PID that does not exist, sysctl succeeds but
  /// returns no bytes, so the size and the PID are both checked.
  ///
  /// A zombie has exited and only waits for its parent to collect it. It still has a record, but
  /// it is not running, so a socket it left behind must carry none of its authority.
  private static func record(of pid: pid_t) -> kinfo_proc? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size

    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }

    guard size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return nil }

    guard info.kp_proc.p_stat != CChar(SZOMB) else { return nil }

    return info
  }
}
