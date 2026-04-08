# Flight

Mac-native SwiftUI app for orchestrating parallel Claude Code agents in isolated git worktrees. Like Conductor.build but open and cloud-capable.

## What It Does

1. Manage git repos in a sidebar
2. Create/delete git worktrees per repo (stored in ~/flight/worktrees/{repo}/{branch}/)
3. Each worktree runs a Claude Code agent as a subprocess
4. Agent output (stream-json format) rendered as a chat UI
5. User types messages in a GUI input bar — the app writes them to the agent's stdin
6. Multiple worktrees run in parallel — each is independent
7. GitHub PR status and CI integration per worktree
8. Paste images into chat (Cmd+V) to send to Claude as context

## Claude CLI Integration

Spawn claude directly via Swift `Process` + `Pipe`. Do NOT use the Agent SDK npm package.

**Local mode:**
```
claude --output-format stream-json --input-format stream-json --verbose --dangerously-skip-permissions --sandbox
```
Set `Process.currentDirectoryURL` to the worktree path. Sandbox scopes writes to that directory.

**Cloud mode:**
Cloud mode is configured per project via provision/connect/teardown commands. Flight doesn't know anything about your infra — it just runs your scripts.

In `~/flight/config.json`:
```json
{
  "cloudMode": {
    "provision": "my-coder-wrapper provision {branch}",
    "connect": "coder ssh {workspace} --",
    "teardown": "my-coder-wrapper teardown {workspace}"
  }
}
```

On worktree create in cloud mode:
1. Flight runs the `provision` command, substituting `{branch}`. Your script does whatever it needs (create Coder workspace, clone repo, checkout branch) and prints the workspace name to stdout.
2. Flight captures that workspace name and substitutes it into the `connect` template.
3. Agent spawn becomes: `coder ssh {workspace} -- claude --output-format stream-json ...`

Same stdin/stdout pipe — SSH is transparent. On worktree teardown, Flight runs the `teardown` command.

**Stream-json output format:** newline-delimited JSON. Each line is a complete JSON object. Key shapes:
- Assistant text: `{"type": "assistant", "message": {"content": [{"type": "text", "text": "..."}]}}`
- Tool use: `{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Write", "input": {...}}]}}`
- Tool result: `{"type": "assistant", "message": {"content": [{"type": "tool_result", "content": "..."}]}}`

Parse each line independently with JSONDecoder. For MVP, treat all content as text — don't try to render rich diffs or syntax highlighting.

**Sending user input:** Write JSON to stdin: `{"type": "user", "message": {"role": "user", "content": "your message"}}`

Note: the bidirectional stream-json protocol is poorly documented. If it's flaky, fall back to spawning a new `claude -p "message" --output-format stream-json` process per user message and use `--resume` to continue the conversation.

## Layout

```
┌──────────────┬─────────────────────────────────────┐
│ Sidebar      │ Chat View                           │
│              │                                     │
│ Projects     │ Streaming messages rendered as       │
│  ▸ mirage    │ chat bubbles. Assistant, tool use,   │
│    ├ main    │ tool results shown inline.           │
│    ├ feat-x ●│                                     │
│    └ fix-y ✓ │                                     │
│              │                                     │
│ + Add Repo   ├─────────────────────────────────────│
│              │ Input bar: [message...] [Send]       │
│              │ Supports Cmd+V image paste           │
└──────────────┴─────────────────────────────────────┘
```

Clicking a worktree in the sidebar shows its chat. Status indicators: gray=idle, green=running, red=error, blue=done. If a PR exists, show a small GitHub icon with CI status (green check, red X, yellow dot).

## Keyboard Shortcuts

- Cmd+N — New worktree (prompts for branch name)
- Cmd+W — Remove current worktree
- Cmd+1-9 — Switch worktrees
- Cmd+Enter — Restart agent
- Cmd+. — Kill agent
- Cmd+K — Clear chat
- Cmd+V — Paste image from clipboard into chat

## Git Worktree Management

```bash
# Create
git -C {repo_path} worktree add ~/flight/worktrees/{repo}/{branch} -b {branch}

# Delete (clean: removes branch, prunes)
git -C {repo_path} worktree remove ~/flight/worktrees/{repo}/{branch}
git -C {repo_path} branch -d {branch}

# List
git -C {repo_path} worktree list --porcelain
```

On worktree create, copy `.context/` from repo root into the worktree if it exists.

**Archive worktree** should be a single clean operation: squash merge PR if merged, `git worktree remove`, prune the branch, clean up the ~/flight/worktrees directory. No orphaned directories.

## GitHub Integration

Use `gh` CLI (must be on PATH and authed) for all GitHub operations. No direct API calls for MVP.

**Per worktree, track:**
- PR number (stored after `gh pr create`)
- CI check status (poll via `gh pr checks {number} --json`)

**Key operations:**
- Create PR from worktree: `gh pr create --head {branch} --fill` (run from worktree dir)
- Get CI status: `gh pr checks {pr_number} --repo {owner/repo} --json name,state,conclusion`
- Get failed CI logs: `gh run view {run_id} --log-failed`
- On CI failure: show a "Fix CI" button in the UI that pipes the failed logs back to the agent as a new message like "CI failed with these errors: {logs}. Please fix."

**PR status display:**
- Show CI status badge next to worktree in sidebar
- Worktree detail view shows PR link, review status, check status
- Poll every 30 seconds when a PR is open (or use `gh` with `--watch` if available)

## Image Paste Support

When user pastes an image (Cmd+V), detect `NSImage` on the clipboard:
1. Save the image to a temp file in the worktree (e.g. `.flight/pasted-{timestamp}.png`)
2. Show a thumbnail preview in the input bar before sending
3. Send to Claude via stdin as a message referencing the image path

Claude Code supports image input natively. The exact mechanism for passing images via stream-json stdin needs to be tested — it may require base64 encoding in the message content as an `image` block, or it may work by just referencing the file path in the user message and letting Claude's file read tool pick it up. Test both approaches; the file path approach is simpler and more likely to work for MVP.

## Persistence

`~/flight/config.json` — projects, worktrees, and PR numbers. Chat history is ephemeral.

## Build Phases

### Phase 1: MVP (build this now)
- SwiftUI app, sidebar with projects and worktrees
- Add/remove repos (directory picker)
- Create/delete worktrees with clean lifecycle
- Spawn Claude CLI per worktree, parse stream-json, render chat
- Send messages via stdin
- Status indicators (agent status + CI status)
- Keyboard shortcuts
- GitHub PR creation from worktree
- GitHub CI status polling and display
- "Fix CI" button that sends failure logs to agent

### Phase 2: Polish
- Image paste support (Cmd+V)
- Execution mode toggle (local vs cloud) with configurable provision/connect/teardown scripts
- .context/ template support
- Collapsible tool use / thinking blocks
- Archive worktree (clean removal + branch prune)

## Constraints

- macOS 14+, SwiftUI, @Observable (not ObservableObject)
- No external dependencies. Foundation Process, Pipe, JSONDecoder only.
- Single Xcode project
- Claude CLI and gh CLI must be on user's PATH — don't bundle them
- Keep it minimal. No features not listed here.
