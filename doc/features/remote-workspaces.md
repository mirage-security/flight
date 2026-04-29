# Remote Workspaces

## Concepts

**Workspace** — a remote machine (e.g. EC2 instance via Coder, a raw SSH host, anything). Long-lived, provisioned once, shared across multiple worktrees. Identified by a name (e.g. `flight-soft-gem-62ea`).

**Worktree** — a session/branch running on a workspace. Each worktree has its own conversation with Claude. Multiple worktrees can run on the same workspace simultaneously.

**Local worktree** — 1:1 with a git worktree directory on your Mac. No workspace concept. Provisioned via `git worktree add`, torn down via `git worktree remove`.

**Remote worktree** — many-to-one with a workspace. Connected via an SSH-compatible wrapper the project provides. Claude runs on the remote machine.

## Data Model

```
Project
  ├─ remoteMode: RemoteModeConfig?    ← settings-level templates (optional)
  │
  ├─ Worktree (local)
  │    ├─ branch: "flight/cool-fox-a3b2"
  │    ├─ path: "~/flight/worktrees/<repo>/flight/cool-fox-a3b2"
  │    ├─ isRemote: false
  │    └─ conversations: [Conversation]
  │
  ├─ Worktree (remote, provisioned)
  │    ├─ branch: "flight/wild-fin-97af"
  │    ├─ workspaceName: "flight-wild-fin-97af"  ← shared across worktrees
  │    ├─ remoteURL: "https://flight-wild-fin-97af.example.com"
  │    ├─ remoteSSHTarget: "coder.flight-wild-fin-97af"
  │    ├─ remoteRepoPath: "/home/ubuntu/my-repo"
  │    ├─ isRemote: true
  │    └─ conversations: [Conversation]
  │
  └─ Worktree (remote, attached to same workspace)
       ├─ branch: "flight-wild-fin-97af/abcd"
       ├─ workspaceName: "flight-wild-fin-97af"  ← same workspace as above
       ├─ isRemote: true
       └─ conversations: [Conversation]
```

Key relationship: multiple worktrees can share a `workspaceName`. The workspace (machine) is only torn down when the last worktree referencing it is removed.

## Configuration

Remote mode has two sources, with settings taking precedence over on-disk scripts on a per-lifecycle basis:

1. **`.flight/<lifecycle>` in the repo** — executable shell script, committed to the repo so the whole team uses the same provisioning flow. This is the intended default.
2. **`project.remoteMode.<lifecycle>` in `~/flight/config.json`** — shell command string, configurable via Settings > Remote. Overrides the on-disk script for local iteration or per-machine overrides.

Any lifecycle with no script and no settings entry is considered unset. Provision and connect are required for remote mode to work; teardown, list, and monitor are optional.

Different projects can use different infra (Coder, EC2 via raw SSH, a GPU cluster, etc.) or have no remote mode at all — the scripts are the abstraction layer.

## Lifecycle scripts

Lifecycle commands run via `zsh -l -c` with `cwd` set to the repo root. Each gets a specific environment and argv contract:

### `provision`

**Env:** `FLIGHT_BRANCH` — the newly generated branch name (e.g. `flight/wild-fin-97af`).

**Contract:**
- Stream progress to stdout. Flight shows each line in the chat UI as a system message (UI only — not sent to Claude's context).
- Emit `FLIGHT_OUTPUT: key=value` lines for structured metadata (see below). These are parsed out and stripped from the displayed log.
- Print the created workspace name as the **last non-metadata line** of stdout.
- Exit 0 on success, non-zero on failure. Flight does NOT manage timeouts; the script runs until it completes or its Task is cancelled.

### `connect`

**Env:** `FLIGHT_WORKSPACE` — the workspace name returned by provision.

**Contract:** the command receives the remote invocation as `"$@"` and is expected to run it on the workspace (ssh-style wrapper). A minimal Coder implementation:

```bash
#!/usr/bin/env bash
exec coder ssh "${FLIGHT_WORKSPACE:?}" -- "$@"
```

Flight calls this every turn to run a `claude -p …` invocation remotely.

### `teardown` optional

**Env:** `FLIGHT_WORKSPACE`.

**Contract:** destroy the workspace. Runs when the **last** worktree referencing that `workspaceName` is removed. If other worktrees still share the workspace, teardown is skipped.

### `list`

**Env:** none.

**Contract:** print one running workspace name per line. Populates the "attach to existing" chips in the remote prompt sheet. Empty output is fine.

### `monitor`

**Env:** `FLIGHT_WORKSPACE` for remote worktrees.

**Contract:** print JSON for the Services rail, exit quickly, and avoid long-running tails or watch modes. Flight times out monitor refreshes after 8 seconds. The payload may be an array of services or an object with a `services` array. Each service has `name`, optional `status`, optional `health` (`healthy`, `warning`, or `critical`), and optional `metrics`.

Example `.flight/monitor`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Replace this with your process supervisor, orchestrator, or health endpoint.
cat <<'JSON'
[
  {
    "name": "web",
    "status": "online",
    "health": "healthy",
    "metrics": [
      { "label": "uptime", "value": "2d 0h" },
      { "label": "restarts", "value": "0" }
    ]
  }
]
JSON
```

## `FLIGHT_OUTPUT` metadata protocol

Provision scripts can emit lines matching `FLIGHT_OUTPUT: key=value` to hand structured data back to Flight. These lines are stripped from the displayed log. Recognised keys:

| Key | Consumed by | Description |
|---|---|---|
| `url` | Chat header "Open URL" button | Browser URL for the workspace (web IDE, dashboard). Right-click gives "Copy URL". |
| `ssh_target` | "Open in VS Code" button | Value that follows `ssh-remote+` in a VS Code Remote-SSH URL. E.g. `coder.my-workspace` or `user@host`. |
| `repo_path` | "Open in VS Code" button | Path to the repo checkout on the remote. E.g. `/home/ubuntu/my-repo`. |

Unknown keys are silently ignored, so adding new ones is forward-compatible. Missing keys disable the features that need them (the VS Code button won't appear for a remote worktree without `ssh_target` AND `repo_path`).

## Flows

### 1. Provision new workspace (Cmd+Shift+N → pick project → "New")

1. User triggers Cmd+Shift+N. If multiple projects have remote support, a picker opens to select one. Otherwise the remote prompt sheet opens directly.
2. User types a prompt, selects "New".
3. Flight generates a random branch name (`flight/calm-owl-a3b2`).
4. Worktree appears immediately in the sidebar with "creating" status.
5. Runs `provision` with `FLIGHT_BRANCH` set, streaming output to the provisioning log group in the chat.
6. `FLIGHT_OUTPUT` lines are captured and applied to the worktree.
7. The last non-metadata line is captured as the workspace name.
8. Flight calls `startAgent` which builds the remote invocation: `zsh -l -c '<connect command>' _ '<claude invocation>'`. Text-only turns pass the prompt as an argument; turns with image attachments embed a base64 JSON payload in the remote command, decode it to temporary PNG files on the remote, and pass those paths in the prompt.
9. First turn sends the initial prompt. A notification fires when the first response arrives.

### 2. Attach to existing workspace (Cmd+Shift+N → pick project → select workspace)

1. The remote prompt sheet fetches `list` output and shows running workspaces as chips alongside "New".
2. User picks a workspace and types a prompt.
3. Flight creates a new worktree entry pointing at that workspace (no provisioning).
4. Spawns a fresh Claude session via connect — no `--resume`, since it's a new conversation.
5. Sends the initial prompt.

This lets you run multiple independent Claude sessions on the same machine without re-provisioning.

### 3. Remove remote worktree

1. Stop the agent(s), delete chat history.
2. Check if any other worktrees share the same `workspaceName`.
3. If yes → just remove the worktree entry (workspace stays running).
4. If no → run `teardown` when configured. On success or when no teardown script exists, silently drop the worktree from Flight. On failure, surface the error and still drop the worktree — the assumption being "the user can always clean up on the host side, but Flight getting stuck is unrecoverable."

## UI

### Sidebar
- Remote worktrees show a cloud icon.
- Per-project `+` creates a local worktree. Shift+click the `+` on a remote-capable project opens the remote prompt sheet for that project.
- Multiple worktrees on the same workspace are independent entries in the list.

### Remote prompt sheet
- Workspace selector at the top: "New" chip (default) + chips for each running workspace from `list`.
- Prompt text editor (multiline, Cmd+Enter to submit, Enter inserts a newline).
- "Launch" (for new) or "Connect" (for existing) button.

### Chat header
- Status dot + branch name.
- Terminal icon: opens a full interactive `claude` session on the remote via tmux (persists outside Flight, shows up in the Claude Code mobile app).
- Link icon: opens the `url` from `FLIGHT_OUTPUT` in the browser. Right-click → Copy URL.
- Code brackets icon: opens the worktree in VS Code. Local worktrees use `code --new-window <path>`; remote worktrees use `code --new-window --remote ssh-remote+<ssh_target> <repo_path>`.

### Settings > Remote
- Project picker at top — each project's remote mode is edited independently.
- Provision / Connect / Teardown / List text fields. When a corresponding `.flight/<name>` exists in the repo, a small pill appears next to the label showing whether the settings entry is overriding it or the on-disk script is being used.
- Save handles both "add/update" and "clear" (empty all fields and save to drop the settings entry).
