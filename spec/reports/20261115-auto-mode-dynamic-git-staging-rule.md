# Teaching auto mode to reject computed git staging

Written 2026-11-15. This report records how the user's Claude Code auto mode was taught to block a `git add` and
`git commit` whose paths are computed at run time. It also records what was left undone.

The environment was Claude Code on macOS (Darwin 25.6.0) in the uniterm checkout, branch `agent/petunia`. The
observations come from the local machine only.

## Summary

A custom `soft_deny` rule named "Dynamic Git Staging" is now active in the user's `~/.claude/settings.json`. It makes the
auto mode classifier likely to block the command that triggered this work. It cannot guarantee a block. A PreToolUse
hook would guarantee one. The hook was drafted but is not installed.

| Finding | Status |
|---|---|
| The command sweeps every untracked file into the commit | Confirmed by reading the command |
| A custom `soft_deny` list replaces the built-in list unless it contains `"$defaults"` | Confirmed by the auto mode docs. See Sources |
| The rule is loaded and merged with the 72 built-in rules | Confirmed: 73 rules after the edit |
| The rule blocks the original command | Not tested |
| A PreToolUse hook deny runs before the classifier | Inferred from the docs. The docs do not say it in plain words |
| The hook is installed | No. It was drafted only |

## The command and why it was unsafe

The auto mode classifier let this command through with a warning. The user wanted it rejected.

```
cd /Users/ripta/projects/uniterm; NEW=("${(@f)$(git ls-files --others --exclude-standard)}"); MOD=("${(@f)$(git diff --name-only)}"); echo ${#NEW} ${#MOD}; git add -- "${NEW[@]}" && git commit -q -F "$TMPDIR/m2msg.txt" -- "${NEW[@]}" "${MOD[@]}"; git log --oneline -1; git status --short
```

The warning was:

```
dangerous operation not ruled out - the shell may read this command differently than it was parsed
```

Three problems:

1. The file list comes from `git ls-files --others` and `git diff --name-only` at run time. It includes every untracked
   file, among them files from other sessions sharing the checkout. This is the effect of `git add -A`, which the
   user's standards forbid.
2. The `${(@f)$(...)}` expansion is zsh-only. The parser could not tell which paths would be committed.
3. The `;` separators run `git log` and `git status` even when the commit fails.

## What was checked

Each command below was run in the repo root.

The built-in rules and their shape:

```
claude auto-mode defaults | jq 'keys'
```

The output keys were `allow`, `environment`, `hard_deny`, and `soft_deny`. The command
`claude auto-mode defaults | jq '.soft_deny | length'` printed `72`.

The user's settings before the change had no custom rules:

```
jq '{autoMode}' ~/.claude/settings.json
```

The output was `{"autoMode": null}`.

The merge semantics came from the Claude Code docs, read by a subagent. The relevant sentences:

> Setting any of `environment`, `allow`, `soft_deny`, or `hard_deny` without `"$defaults"` replaces the entire default
> list for that section.

> To keep the built-in rules while adding your own, include the literal string `"$defaults"` in the array.

`autoMode` counts only in the user's `~/.claude/settings.json`. The classifier ignores it in a project's
`.claude/settings.json` and `.claude/settings.local.json`.

After the user edited the settings, the merged result was checked:

```
claude auto-mode config | jq '{n: (.soft_deny | length), custom: [.soft_deny[] | select(startswith("Dynamic Git Staging")) | test("literal subdirectory after `git commit --`")]}'
```

The output was `{"n": 73, "custom": [true]}`. That is the 72 built-in rules plus the one custom rule.

## The rule

The rule went through three rounds of `claude auto-mode critique`. The critique is model feedback, not a test.

The first critique asked for a consent slot, a wider list of sweep forms, and the removal of a "parser warning" clause.
The classifier never sees parser output, so that clause could do nothing. A planted string in tool output could also
have triggered it.

The second critique caught four problems:

- The `gitStatus` rationale described the line as a session-start snapshot. The classifier prompt says it is taken as
  the command starts.
- A bare `git commit` was ambiguous.
- The directory carve-out conflicted with the rule's purpose.
- Consent scope was unstated.

The user then chose to allow literal directories after `git commit --`. That choice trades some safety for fewer
prompts. Such a commit includes tracked edits that another session made under that directory.

The final rule, as installed:

```json
"Dynamic Git Staging [named+specifics — **must name:** the sweep (\"commit everything\", \"add all changes\") or the specific files to stage]: A `git add`, `git stage`, `git update-index --add`, or `git commit` whose paths are not all literal paths in the command. A `git commit` must name its paths after `--`; a bare `git commit` with no pathspec is this rule, because it commits whatever another session sharing the checkout may have staged. A literal subdirectory after `git commit --` is allowed, since it commits only tracked changes; `.`, `:/`, and the repo root are not. On `git add`, every path must be a literal file; a directory pathspec is this rule. Covered: sweeps (`-A`, `--all`, `-u`, `.`, `:/`, `-a`, `-am`, `--amend -a`, `--include`), glob pathspecs (shell or git), `-p`/`-i`, `-f`/`--force`, and paths computed at run time (command substitution, variables or arrays, `xargs`, `ls-files`/`diff` output, `--pathspec-from-file`), or any equivalent. Treat a path as a file unless it ends in `/` or the transcript shows it is a directory. Purpose: keep untracked files, and other sessions' changes, out of commits. Applies regardless of any gitStatus meta line. Consent covers only the commit it was given for, and never clears the Credential Leakage check on sensitive files. Exempt: throwaway clones whose creation by the agent is visible in this transcript. Agent-created worktrees are not exempt."
```

It sits in `autoMode.soft_deny` after a `"$defaults"` entry.

## Open items

Hypotheses:

- A PreToolUse hook that denies on a regex match would block every time, where the classifier only usually does. The
  docs say a hook `deny` prevents the call. They do not say it runs before the classifier.

Open questions:

- Does the classifier block the original command? Test it with a harmless variant such as
  `git add -- $(echo README.md)`.
- Does blocking a bare `git commit` cause prompts in existing flows? If it does, find which skill or agent commits
  without paths.

## Remediation options

The hook is optional. Install it for a guaranteed block.

| Option | Trade-off |
|---|---|
| Classifier rule only (current) | No code to maintain. A differently written command can still pass |
| Add a PreToolUse hook on `Bash` | Always blocks. The regex must be tuned to allow `git commit -- <dir>` and `-F "$TMPDIR/msg.txt"`, or it over-blocks |

The drafted hook matched `git add` or `git commit` together with `$(`, backticks, `${`, `$VAR`, `xargs`, `-A`, `.`, or
`-a`. It would deny a message file given as `-F "$TMPDIR/..."`. That is a known false positive of the draft.

## Status

Changed:

- The user added `autoMode.soft_deny` with the rule above to `~/.claude/settings.json`. The agent could not write there
  and did not.

Analysis only:

- The hook script. It was never installed.

Open:

- The rule is untested against the original command.
- The hook decision is the user's.

## Sources

- https://code.claude.com/docs/en/auto-mode-config
- https://code.claude.com/docs/en/hooks
- https://code.claude.com/docs/en/permissions
