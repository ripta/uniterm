# Queue

| Milestones | Depends on | Note |
|------------|------------|------|
| UTERM-022 M1-M4 | UTERM-021 M4 | M3's question-only session builds on UTERM-021 M4's strict mode, begins, and command authentication |
| UTERM-041 M1-M2 | None | |
| UTERM-042 M1-M3 | UTERM-041 M2 | M2 builds on UTERM-041 M1's tab bar and markers. M3 builds on its chip. M1 needs neither |
| UTERM-019 M1-M2 | None | Split from M3: M1-M2 need nothing from UTERM-041 or UTERM-042 |
| UTERM-019 M3 | UTERM-041 M1, UTERM-042 M2 | Split from M1-M2: M3 publishes the run-end marker. It needs UTERM-041 M1's slot and UTERM-042 M2's "Rebuild Tab" menu, so the marker never ships without a way to rebuild the tab |
| UTERM-019 M4-M6 | None | Split after M3: these follow M3 in order and need nothing more from these proposals |
