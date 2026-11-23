Intentionally retained legacy ids (compat aliases, boot-migration sources) are protected from `tools/rename_dot_to_gs.py` with a marker in the line itself.

| Marker | Protects |
|---|---|
| `gs-rename: keep` anywhere on a line (a trailing comment in any syntax) | that line |
| `gs-rename: keep-next` | the line after the marker (JSON and other formats with no comment on the line) |
| `gs-rename: keep-begin` ... `gs-rename: keep-end` | every line between, marker lines included |

A protected line is never rewritten (all phases), never reported by `--check`, and accepted by `tools/audit_old_names.py` without an allowlist line.
`tools/audit_old_names.allow` still works for what cannot carry a marker (binaries, tsv rows, lines in code fences or heredocs); an allowlist line that matches nothing is still reported stale.
Put the reason beside the marker, for example `'arena_weapons' { return 'fc-weapons' }  # gs-rename: keep (legacy id)`.
The rename tool is idempotent with markers: `tools/test_rename_dot_to_gs.py` reruns it and compares.
