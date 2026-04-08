# Remote Workspaces

## Concepts

**Workspace** — a remote machine (e.g. EC2 instance via Coder). Long-lived, provisioned once, shared across multiple worktrees. Identified by a name (e.g. `flight-soft-gem-62ea`).

**Worktree** — a session/branch running on a workspace. Each worktree has its own conversation with Claude. Multiple worktrees can run on the same workspace simultaneously.

**Local worktree** — 1:1 with a git worktree directory on your Mac. No workspace concept. Provisioned via `git worktree add`, torn down via `git worktree remove`.

**Remote worktree** — many-to-one with a workspace. Connected via SSH tunnel (`coder ssh {workspace} --`). Claude runs on the remote machine.

## Data Model

```
Project
  └─ Worktree (local)
       ├─ branch: "flight/cool-fox-a3b2"
       ├─ path: "~/flight/worktrees/mirage/flight/cool-fox-a3b2"
       ├─ isRemote: false
       └─ conversations: [Conversation]

  └─ Worktree (remote)
       ├─ branch: "flight/wild-fin-97af"
       ├─ workspaceName: "flight-wild-fin-97af"  ← shared across worktrees
       ├─ isRemote: true
       └─ conversations: [Conversation]

  └─ Worktree (remote, same workspace)
       ├─ branch: "flight-wild-fin-97af"         ← attached, reusing workspace
       ├─ workspaceName: "flight-wild-fin-97af"  ← same workspace
       ├─ isRemote: true
       └─ conversations: [Conversation]
```

## Config

In `~/flight/config.json`:

```json
{
  "remoteMode": {
    "provision": "~/flight/flight-provision {branch}",
    "connect": "coder ssh {workspace} --",
    "teardown": "coder delete {workspace} --yes"
  }
}
```

- `{branch}` — substituted with the generated branch name
- `{workspace}` — substituted with the workspace name (from provision output or user selection)

## Flows

### 1. Provision new workspace (Shift+Cmd+N → "New")

1. User types a prompt, selects "New"
2. Flight generates a random branch name (`flight/calm-owl-a3b2`)
3. Runs `provision` command, streaming output to chat UI
4. Provision script outputs workspace name as last line of stdout
5. Flight captures workspace name, builds connect prefix
6. Spawns Claude via `coder ssh {workspace} -- claude -p --output-format stream-json ...`
7. Sends initial prompt to Claude

### 2. Attach to existing workspace (Shift+Cmd+N → select workspace)

1. User types a prompt, selects a running workspace from the list
2. Flight creates a new worktree entry pointing at that workspace
3. Skips provisioning entirely
4. Spawns Claude via same connect prefix — new session (no `--resume`)
5. Sends initial prompt to Claude

This lets you run multiple independent Claude sessions on the same machine.

### 3. Remove remote worktree

1. Stop agent, clean up conversations/chat history
2. Check if any OTHER worktrees reference the same `workspaceName`
3. If yes — just remove the worktree entry (workspace stays running)
4. If no — run `teardown` command to destroy the workspace

## Provision Script Protocol

The provision script must:
- Accept `{branch}` as its argument
- Stream progress to stdout (Flight displays each line in the chat UI)
- Print the workspace name as the **last line** of stdout
- Exit 0 on success, non-zero on failure
- Handle its own error cases (coder not installed, not authed, etc.)

Flight does NOT manage timeouts — the script runs until it completes or is cancelled (via Task cancellation, which sends SIGTERM).

## UI

### Sidebar
- Remote worktrees show a cloud icon
- Multiple worktrees on the same workspace are independent entries
- Status indicators work the same (idle/working/ready/error)

### Shift+Cmd+N Dialog
- Top: workspace selector — "New" (default) + chips for each running workspace
- Running workspaces fetched via `coder list --output json`
- Middle: prompt text editor
- Bottom: "Launch" (new) or "Connect" (existing) button, Cmd+Enter shortcut

### Chat
- Provisioning progress streams as system messages (UI-only, not sent to Claude)
- "Connecting to {workspace}..." message on attach
- "Workspace {name} ready. Connecting agent..." on provision complete
