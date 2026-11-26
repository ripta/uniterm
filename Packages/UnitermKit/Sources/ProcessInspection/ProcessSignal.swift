import Darwin

extension ProcessInspection {
  /// What `signal(_:pid:startedMicroseconds:)` did.
  public enum SignalResult: Equatable, Sendable {
    /// The signal went to the process the audit token named, which is the recorded process or that
    /// process after an exec.
    case byToken

    /// The system gave no audit token, so the signal went to the pid after the start time matched.
    /// A reuse of the pid between that check and the signal is not ruled out.
    case byPid

    /// The pid names no live process with the recorded start time. Nothing was sent.
    case gone

    /// The recorded process still runs, but no signal reached it. Nothing was sent to any other
    /// process.
    case unreached

    /// The pid is 1 or below, or the caller's own. Nothing was sent.
    case refused
  }

  /// How many audit tokens one signal reads at most. An exec between a token's read and its use
  /// stales the token, so a token signal that finds no process reads a fresh one and tries again.
  static let tokenTries = 3

  /// Sends signal `number` to `pid` only while it is the process that started at
  /// `startedMicroseconds`, as `startTimeMicroseconds(of:)` read it.
  ///
  /// Each try reads a fresh audit token for the pid, then reads the start time again. When the
  /// start time matches, the token names the recorded process, or that process after an exec, and
  /// the kernel delivers only to the process the token names. A pid that moved on in between fails
  /// the start-time match, or the token signal finds no process. Either way no other process is
  /// signalled.
  ///
  /// When the first try reads no token, the signal goes to the pid once the start time matches.
  /// That leaves a window between the check and the signal.
  ///
  /// A token signal that finds no process is retried with a fresh token. A retry never falls back
  /// to the pid, since the token signal has already shown that the pid may name another process.
  ///
  /// The token signal answers EINVAL for signal 0. So a signal 0 probe with a token reports
  /// unreached, and without one the pid path sends it.
  public static func signal(_ number: Int32, pid: pid_t, startedMicroseconds: Int) -> SignalResult {
    signal(number, pid: pid, startedMicroseconds: startedMicroseconds, readToken: auditToken(of:))
  }

  /// The guarded signal with the token reader injected, so a test can hand it a stale token.
  static func signal(
    _ number: Int32, pid: pid_t, startedMicroseconds: Int, readToken: (pid_t) -> audit_token_t?
  ) -> SignalResult {
    guard pid > 1, pid != getpid() else { return .refused }

    for attempt in 0..<tokenTries {
      let token = readToken(pid)

      guard startTimeMicroseconds(of: pid) == startedMicroseconds else { return .gone }

      guard let token else {
        guard attempt == 0 else { return .unreached }

        guard Darwin.kill(pid, number) == 0 else { return errno == ESRCH ? .gone : .unreached }

        return .byPid
      }

      let status = send(number, to: token)

      if status == 0 { return .byToken }

      guard status == ESRCH else { return .unreached }
    }

    return .unreached
  }

  /// Sends signal `number` to the process `token` names, and returns 0 or an errno value. The
  /// kernel checks the token's pid version, so a token for a process that exec'd or ended gets
  /// ESRCH, a zombie included.
  static func send(_ number: Int32, to token: audit_token_t) -> Int32 {
    var token = token
    let status = proc_signal_with_audittoken(&token, number)

    return status == -1 ? errno : status
  }

  /// The audit token of the process `pid` names now, or nil when the system gives none. A zombie
  /// gives none. The task name port the read takes is released on every path.
  static func auditToken(of pid: pid_t) -> audit_token_t? {
    var port = mach_port_name_t(MACH_PORT_NULL)

    guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else { return nil }

    defer { mach_port_deallocate(mach_task_self_, port) }

    var token = audit_token_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)

    let status = withUnsafeMutablePointer(to: &token) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
      }
    }

    guard status == KERN_SUCCESS, token.val.5 == UInt32(bitPattern: pid) else { return nil }

    return token
  }
}
