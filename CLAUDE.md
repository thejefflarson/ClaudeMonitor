# ClaudeMonitor — agent notes

## Build system

This project uses **xcodegen** (`project.yml`) — never edit `ClaudeMonitor.xcodeproj` by hand.

```bash
xcodegen generate          # regenerate .xcodeproj after editing project.yml
xcodebuild test -scheme ClaudeMonitor -destination 'platform=macOS'
```

## Key data sources

All data comes from local Claude Code files — no network calls at runtime.

| Data | Source |
|---|---|
| Month-to-date cost & tokens | `~/.claude/projects/**/*.jsonl` — `message.usage` fields on assistant messages |
| Active sessions | `~/.claude/projects/{project-slug}/{sessionId}.jsonl` — file modification time |
| Task state | `~/.claude/tasks/{sessionId}/{taskId}.json` — one JSON file per task |

## Polling intervals

- **Usage**: every 5 minutes (`AppStore.usageTask`)
- **Sessions + tasks**: every 5 seconds (`AppStore.logsTask`)

## Session visibility rules (`LocalLogsService.activeSessions`)

A session is included if **either**:
1. Its JSONL was modified within the last 300 seconds, **or**
2. It has a task directory in `~/.claude/tasks/` with any non-completed/non-deleted task

## Project path decoding

Session JSONL files live at `~/.claude/projects/{encoded-path}/{sessionId}.jsonl`.
The encoded path uses `-` as a path separator (e.g. `-Users-jeff-dev-chirp` → `~/dev/chirp`).
`LocalLogsService.projectPathFromDir(_:)` handles this decoding.

## Cost estimation

Model family is detected by checking if `message.model` contains `"opus"` or `"haiku"` (sonnet is the default). Prices are hardcoded in `LocalLogsService.estimateCost`. Update them there when Anthropic changes pricing.

## Release process

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`
2. Commit, push, tag (`git tag vX.Y.Z && git push origin vX.Y.Z`)
3. `gh release create vX.Y.Z --title "vX.Y.Z" --notes "..."`

## What NOT to do

- Don't use the Anthropic API for usage data — the org-level endpoints (`/v1/organizations/cost_report`) require an Admin API key that only works with organization accounts, not individual users.
- Don't parse task state from JSONL history — `~/.claude/tasks/` is the canonical source and is much simpler to read.
