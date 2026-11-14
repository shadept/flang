# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps each role to how it is
expressed in Linear (team `SH`). Some roles are a status, not a label.

| Role in mattpocock/skills | In Linear | Meaning |
| --- | --- | --- |
| `needs-triage` | status **Triage** | The owner needs to evaluate this issue. |
| `needs-info` | label `needs-info` | Waiting for more information. Whoever adds it says what is missing in a comment. |
| `ready-for-agent` | label `agent-ready` | Fully specified; an agent (Cyrus) may pick it up. |
| `ready-for-human` | status **Todo**, no `agent-ready` | Needs the owner. |
| `wontfix` | status **Canceled** | Will not be actioned. Say why in a comment. |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), apply what the right-hand
column says. `needs-info` and `agent-ready` never sit on the same issue: adding one removes the
other.
