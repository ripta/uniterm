# UTERM-023: Controller Runs with SIP Off

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-003, for the bundle's `uniterm` command
- UTERM-004, for the code-hash match that admits a controller run

## Impacts

- UTERM-004 — "Verified artifact and run binding": its loader-variable bullet says dyld removes every `DYLD_` variable
  before the command's code runs. That holds only while System Integrity Protection is on.
- ADR-10 — the command is hardened so that dyld variables cannot reach it. The same limit applies.

## Summary

Decide what uniterm does when it runs on a Mac with System Integrity Protection off. The kernel then leaves `DYLD_`
variables on the hardened `uniterm` command. A library named by `DYLD_INSERT_LIBRARIES` loads into a run that the app
will admit.

## Motivation

The app trusts a controller run only when the caller is the bundle's own command, matched by its code hash. That match
says nothing about code dyld loaded into the command first. With SIP on, the hardened runtime makes the kernel strip
the variables, so nothing loads.

GitHub's macOS runners have SIP off. On the first CI run of the PR that added the hardened command, GuardMalloc loaded
into the command. Three tests caught it. The signature checks passed in the same run, so the command is signed as
intended. The injection is the platform's behavior.

CI now skips the injection probes when SIP is off. That keeps CI green. It changes nothing in the product. A user who
turns SIP off still gets a trust boundary that no longer holds, and nothing says so.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### What uniterm does while SIP is off

The question is whether to change anything. Candidate (a) is no addition. Candidates (b) to (d) each add behavior.

- (a) Treat SIP-off as outside the threat model. UTERM-004 and ADR-10 say so. A user who disables SIP has removed the
  platform protection that the design relies on. Nothing in the product changes. CI keeps skipping the probes.
- (b) Refuse controller runs while SIP is off. The refusal names the reason. This keeps the contract whole. It also
  blocks every controller script on those Macs, including users who accept the risk.
- (c) Warn while SIP is off, and leave the choice to the user. The warning shows on the consent sheet and in the
  Controllers window. The contract is weaker on those Macs, and the user is told so at the point of decision.
- (d) Check at admission that the command loaded only expected images. The command reports its dyld image list and the
  app compares it. Injected code can falsify the report, so this catches only careless injection. It adds a new
  mechanism that proves less than it appears to.

Open: how the app reads SIP state. `csrutil status` needs a process launch. A syscall or a framework call may be
cheaper. This depends on the answer above, and only matters for (b) and (c).

## Risks

- **A user turns SIP off and relies on a trust boundary that no longer holds** — likelihood: low, impact: high.
  Mitigation: depends on the chosen candidate. Under (a), the documentation says so. Under (b) and (c), the app says so.
- **The SIP check misreads state and blocks or warns wrongly** — likelihood: low, impact: medium.
  Mitigation: applies to (b) and (c) only. Fail toward warning, not toward blocking, when the state cannot be read.

## Milestones

### M1: Settle the SIP-off behavior

**Status:** NOT STARTED

Milestones follow once the open decision is settled.

- The user picks a candidate, and UTERM-004 and ADR-10 are updated to match it

## Decision Log

- 2026-11-15: Filed from a triaged bug. The bug records the CI evidence. It is linked from the bug file.

## References

- ADR-10: app unsandboxed, helpers sandboxed
- UTERM-004: control and trust
