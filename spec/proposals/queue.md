# Queue

| Milestones | Depends on | Note |
|------------|------------|------|
| UTERM-041 M1-M2 | None | |
| UTERM-042 M1-M3 | UTERM-041 M2 | M2 builds on UTERM-041 M1's tab bar and markers. M3 builds on its chip. M1 needs neither |
| UTERM-019 M1-M2 | None | Split from M3: M1-M2 need nothing from UTERM-041 or UTERM-042 |
| UTERM-019 M3 | UTERM-041 M1, UTERM-042 M2 | Split from M1-M2: M3 publishes the run-end marker. It needs UTERM-041 M1's slot and UTERM-042 M2's "Rebuild Tab" menu, so the marker never ships without a way to rebuild the tab |
| UTERM-019 M4-M6 | None | Split after M3: these follow M3 in order and need nothing more from these proposals |
| UTERM-032 M1-M2 | None | |
| UTERM-024 M1-M2 | UTERM-032 | New permission kinds follow UTERM-032's rule on where a kind may appear |
| UTERM-030 M1-M2 | UTERM-032, UTERM-024 | Slide images load from UTERM-032's granted folder. The Markdown page opts in to UTERM-024's controller keys |
| UTERM-025 M1 | UTERM-024, UTERM-030, UTERM-032 | The presenter needs UTERM-024's commands and keys, UTERM-030's slides, and UTERM-032's deck argument |
| UTERM-026 M1-M4 | UTERM-024, UTERM-025, UTERM-032 | The presenter view extends UTERM-025's controller across two windows |
| UTERM-028 M1 | UTERM-024 | Exec drivers gain UTERM-024's commands, keys, and events |
| UTERM-029 M1-M3 | UTERM-024 M2, UTERM-025, UTERM-026, UTERM-030 M2, UTERM-032 M1 | Extends the presenter with UTERM-026's notes window, UTERM-030 M2's slide images, and UTERM-032 M1's input file |
