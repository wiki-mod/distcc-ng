Dieses Mapping ordnet die bisherigen numerischen Regeln der neuen stabilen Rule-ID-Struktur zu. Mehrere alte Regeln können bewusst auf denselben kanonischen Owner zeigen, wenn ihre Semantik konsolidiert wurde.

| Alte Regel | Neue Rule-ID | Hinweis |
|---:|---|---|
| 0 | `[AG-LAW-001]` | Unified rulebook |
| 1 | `[AG-CC-001]` | Sprache |
| 2 | `[AG-GH-001]` | Issue-Verknüpfungen |
| 3 | `[AG-GH-002]` | Metadata / Project / Milestone |
| 4 | `[AG-GH-003]` | Tracking-Issue / Closing Keywords |
| 5 | `[AG-GH-004]` | Partial / Scaffold PR |
| 6 | `[AG-GH-005]` | PR-Body |
| 7 | `[AG-GH-006]` | Post-Merge Completion Check |
| 8 | `[AG-GH-007]` | Beziehungen dauerhaft in GitHub |
| 9 | `[AG-GH-008]` | Tracking-Issue früh anlegen |
| 10 | `[AG-GH-009]` | Laufende GitHub-Updates |
| 11 | `[AG-GH-010]` | Actionable Issues |
| 12 | `[AG-GH-011]` | Follow-up / Successor Issues |
| 13 | `[AG-GH-012]` | Issue Closure Verification |
| 14 | `[AG-WF-001]` | Worktree |
| 15 | `[AG-WF-002]` | Branch Freshness |
| 16 | `[AG-WF-003]` | Rebase / Range-Diff |
| 17 | `[AG-WF-004]` | Subagent Result Verification |
| 18 | `[AG-GH-013]` | `gh --repo` / Repository Targeting |
| 19 | `[AG-WF-005]` | Delegated Model Selection |
| 20 | `[AG-WF-006]` | Nicht auf Subagents blockieren |
| 21 | `[AG-WF-007]` | `master` Merge / Push |
| 22 | `[AG-WF-008]` | Merge / Close / Delete |
| 23 | `[AG-WF-009]` | Draft PR |
| 24 | `[AG-WF-010]` | Review Thread Resolution |
| 25 | `[AG-WF-011]` | Nicht auflösbare Review Threads |
| 26 | `[AG-WF-012]` | Vollständiger Issue-/PR-Kontext |
| 27 | `[AG-WF-013]` | Failure Class / Root Cause |
| 28 | `[AG-DOC-001]` | Dokumentation vs. Realität |
| 29 | `[AG-VAL-002]` | Shell-sichere Suchmuster |
| 30 | `[AG-VAL-001]` | Standardfehler sind harte Fehler |
| 31 | `[AG-INT-003]` | Warnings / Validation Integrity |
| 32 | `[AG-VAL-003]` | Reale Build-/Test-Evidenz |
| 33 | `[AG-VAL-004]` | Workflow Validation |
| 34 | `[AG-VAL-005]` | Shell-/Build-Syntaxprüfung |
| 35 | `[AG-INT-003]` | Checks nicht abschwächen |
| 36 | `[AG-INT-003]` | Fehler nicht unterdrücken |
| 37 | `[AG-VAL-006]` | Verhaltensspezifische Validierung |
| 38 | `[AG-CODE-001]` | Kommentarstandard |
| 39 | `[AG-CODE-001]` | `Why:`-Semantik |
| 40 | `[AG-CODE-001]` | What / Why / From |
| 41 | `[AG-CODE-002]` | Fehlendes `Why:` |
| 42 | `[AG-CODE-003]` | TODO / Placeholder |
| 43 | `[AG-REL-001]` | Release Tag |
| 44 | `[AG-REL-002]` | CHANGELOG |
| 45 | `[AG-REL-003]` | Nightly / Pre-Release |
| 46 | `[AG-SEC-001]` | Credentials / Personal Data |
| 47 | `[AG-SEC-001]` | Secrets / Variables |
| 48 | `[AG-SEC-001]` | Private Hosts / IPs |
| 49 | `[AG-SEC-002]` | Sensitive Data im Branch |
| 50 | `[AG-SEC-003]` | Upstream strikt read-only |
| 51 | `[AG-SEC-004]` | Writes in andere Repositories |
| 52 | `[AG-WF-007]` | Bereits durch alte Regel 21 ersetzt |
| 53 | `[AG-COMP-001]` | Neue Build-/Language Dependency |
| 54 | `[AG-SEC-001]` | Environment-spezifische Werte |
| 55 | `[AG-COMP-002]` | Plattform-/Toolchain-Kompatibilität |
| 56 | `[AG-SEC-005]` | Git Hooks nicht umgehen |
| 57 | `[AG-UP-001]` | Upstream-Bug-Prüfung |
| 58 | `[AG-WF-014]` | PR Scope |
| 59 | `[AG-WF-015]` | Harmless Cleanup |
| 60 | `[AG-WF-016]` | 5-Minuten-Agent-Updates |
| 61 | `[AG-CI-001]` | Workflow-Dateien / Composite Actions |
| 62 | `[AG-INT-001]` | Evidence / No Hallucination |
| 63 | `[AG-INT-002]` | Verifizierbare Commands / RTFM |
| 64 | `[AG-LAW-003]` | Stabile Rule-IDs |
| 65 | `[AG-LAW-004]` | Ein Rulebook / Pointer Files |
| 66 | `[AG-INT-003]` | Keine Signal-Unterdrückung |
| 67 | `[AG-INT-005]` | Lokal prüfen vor externer Recherche |
| 68 | `[AG-LAW-004]` | Bindende Governance-Dateien |
| 69 | `[AG-CODE-004]` | Search-before-implementation |
| 70 | `[AG-REL-004]` | Release Branch |
| 71 | `[AG-GH-014]` | PR Title Convention |
| 72 | `[AG-INT-004]` | Bug vs. Designentscheidung |
| 73 | `[AG-WF-013]` | File-wide Failure-Class Sweep |
| 74 | `[AG-VAL-007]` | Dependency-Bump Review |
| 75 | `[AG-INT-005]` | Full-depth Investigation |
| 76 | `[AG-CODE-006]` | Keine unbelegte Defensive Logic |
| 77 | `[AG-GH-015]` | Findings zusammenfassen |
| 78 | `[AG-WF-017]` | Completion Gates |
| 79 | `[AG-GH-016]` | Resolve / Minimize via GraphQL |
| 80 | `[AG-PROTO-001]` | Protocol Version Numbers |
| 81 | `[AG-WF-018]` | Maintainer Authority |
| 82 | `[AG-SEC-006]` | Admin / Secrets / Ruleset |
| 83 | `[AG-LAW-005]` | Full Read |
| 84 | `[AG-LAW-005]` | Re-read |
| 85 | `[AG-LAW-005]` | Subagent Full-read Relay |
| 86 | `[AG-CODE-005]` | Shared Capability Across Issues |
| 87 | `[AG-VAL-003]` | Buildtools / CI Evidence |
| 88 | `[AG-REL-005]` | Release-PR Process |
| 89 | `[AG-REL-006]` | Release Evidence / Candidate SHA |
| 90 | `[AG-REL-007]` | Release Coverage Gaps |
| 91 | `[AG-WF-001]` | Initial Empty Worktree Commit |

## Konsolidierte Owner

Die wichtigsten bewussten Zusammenführungen sind:

- `38`, `39`, `40` -> `[AG-CODE-001]`
- `31`, `35`, `36`, `66` -> `[AG-INT-003]`
- `83`, `84`, `85` -> `[AG-LAW-005]`
- `65`, `68` -> `[AG-LAW-004]`
- `14`, `91` -> `[AG-WF-001]`
- `27`, `73` -> `[AG-WF-013]`
- `32`, `87` -> `[AG-VAL-003]`
- `21`, `52` -> `[AG-WF-007]`

Die alten numerischen Referenzen SHOULD nach der Migration repo-weit durch die neuen stabilen Rule-IDs ersetzt werden.
"""
