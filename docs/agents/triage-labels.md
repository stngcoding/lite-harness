# Triage Labels

The `triage` skill uses these labels to route issues through their lifecycle.

## Canonical labels

| Label | Meaning | Next step |
| --- | --- | --- |
| `needs-triage` | Maintainer must evaluate the issue | Triage → apply a role label below |
| `needs-info` | Waiting on reporter for clarification | Reporter responds → re-triage |
| `ready-for-agent` | Fully specified, AFK agent can pick up | Agent starts work |
| `ready-for-human` | Needs human judgment or implementation | Human picks up |
| `wontfix` | Will not be actioned | Close issue |

## Applying labels

Use `triage` skill to route issues interactively, or apply labels directly via GitHub:

```bash
gh issue edit <number> --add-label needs-triage
gh issue edit <number> --add-label ready-for-agent
```

Issues without any role label are considered newly-opened and will be picked up by `triage` on the next run.
