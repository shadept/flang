# Issue tracker: Linear

Work on FLang is tracked in Linear, workspace `furtado-interactive`, team **Shade** (`SH`). Use
the Linear MCP tools (`list_issues`, `get_issue`, `list_comments`, `save_issue`, `save_comment`).
The team is shared with other projects, so every FLang issue carries the `flang` label.

The repo keeps the text that lasts: RFCs (`docs/tickets/`), the spec, and limitations by design
(`docs/known-issues.md`). Linear keeps the state that moves: what is open, who acts next, which
phase is underway.

## Labels

Every issue gets one label from each group that applies.

| Group | Labels | Meaning |
| --- | --- | --- |
| Product | `flang` | Required on every FLang issue. |
| Kind | `Bug`, `Feature`, `Improvement`, `RFC` | `RFC` marks an RFC decision ("Decide RFC-NNN"). |
| FLang area | `language`, `compiler`, `stdlib`, `tooling` | May hold more than one. |
| Workflow | `needs-info`, `agent-ready` | See `triage-labels.md`. |

## Statuses

Triage, Backlog, Todo, In Progress, In Review, Done, Canceled. Duplicate marks a duplicate.

## Projects

A project is a finite outcome with an end, named for what FLang can do once it is done:
"FLang serves HTTP (RFC-005)". Ongoing work (bugs, stdlib growth, tooling polish) has no project;
it lives in issues with area labels. All FLang projects belong to the FLang initiative.

Order inside a project comes from milestones; hard ordering comes from "blocked by" relations.
Do not start an issue that is still blocked.

## When a skill says "publish to the issue tracker"

Search first (`list_issues` with `team: SH`, `label: flang`, `query: ...`) so you don't create a
duplicate. Then create the issue in team `SH` with `flang`, one Kind label and the area labels.
New work you are not sure about goes to Triage. Write the description for a person; put plans,
file lists and repro logs in a collapsible "Agent notes" section at the end.

## When a skill says "fetch the relevant ticket"

`get_issue` with the id (`SH-NN`), then `list_comments` for the discussion. If the issue links an
RFC, read the RFC file too: the RFC is the design, the issue is the work.

## While working an issue

- Move it to In Progress when you start and In Review when a PR is up. Done is set when the work
  merges.
- Put the id in the branch name (`sh-12-short-slug`) or PR title (`SH-12: ...`) so Linear links
  the PR.
- If you stop to ask a question, add `needs-info`, remove `agent-ready`, and ask in a comment.
- Found something new? Open a new issue for it instead of widening the current one.

## RFCs

See `docs/tickets/README.md`. In short: each RFC file has `linear: SH-NN` (or `P-SH-N` for a
project). Only the owner approves an RFC. Implement only RFCs with `accepted:` set, and only
issues that are `agent-ready` or assigned to you.
