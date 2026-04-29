# Flight

A Mac-native GUI for orchestrating parallel Claude Code agents across local git worktrees and remote workspaces.

Built as an internal tool for daily agentic coding work. Open-sourced so others can adapt it.

![Remote provisioning](doc/images/remote-provisioning.png)

## What it does

- Manage multiple git repos in a sidebar, switch between projects with a fuzzy picker (Cmd+N / Cmd+Shift+N)
- Spin up isolated git worktrees per task, each running its own Claude Code agent
- Chat with agents in a streaming UI with collapsible tool calls and markdown rendering
- Run agents locally (sandboxed) or remotely via SSH (e.g. Coder, EC2, any machine)
- Add **remote-only projects** with no local clone — Flight fetches `.flight/` scripts from the repo via the forge API and runs everything remotely
- Open worktrees directly in VS Code — local paths or through Remote-SSH for remote workspaces
- Per-worktree CI check status and reviewer feedback (GitHub and Forgejo), with `gh --repo` so remote-only projects get PR/CI too
- Multiple conversations per worktree with tab support
- Base16 theme engine with 6 built-in themes + import support

## Install

Requires macOS 15+ and Swift 6.0+. No Xcode needed.

```bash
git clone https://github.com/mirage-security/flight.git
cd flight
./build.sh
open Flight.app
```

Or run directly:

```bash
swift run Flight
```

Signed releases update themselves through Sparkle. The release workflow and
required Apple/Sparkle credentials are documented in [doc/releasing.md](doc/releasing.md).

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`) on your PATH
- [GitHub CLI](https://cli.github.com/) (`gh`) for PR/CI features (optional)

## Usage

### Local worktrees

1. Click **Add Repo** to add a git repository
2. **Cmd+N** creates a new worktree with a random branch name and starts a Claude agent
3. Chat in the input bar, hit **Enter** to send
4. **Escape** interrupts the agent mid-turn

### Adding a project

Click **Add Project** in the sidebar. The sheet has two modes:

- **Local** — pick a folder on disk. The name defaults to the folder's basename, and you can rename it (handy for having a local `mirage` alongside a remote-only `mirage`).
- **Remote** — point at a forge repo and Flight will fetch its scripts on your behalf. See [Remote-only projects](#remote-only-projects) below.

### Remote workspaces

1. Drop executable lifecycle scripts into `.flight/` in the repo (or configure templates in **Settings > Remote**)
2. **Cmd+Shift+N** opens a project picker → select the project → the remote prompt sheet appears
3. Pick "New" to provision a fresh workspace, or an existing one from the list
4. Type your initial prompt and hit **Cmd+Enter**

Remote mode is backend-agnostic. You provide lifecycle scripts in `.flight/` at the repo root:

| Script | Env | Args | Purpose |
|---|---|---|---|
| `.flight/provision` | `FLIGHT_BRANCH` | — | Create a workspace. Prints workspace name as last line of stdout. Can emit `FLIGHT_OUTPUT: key=value` metadata (see below). |
| `.flight/connect` | `FLIGHT_WORKSPACE` | `"$@"` | SSH wrapper. Runs its argv on the remote workspace. e.g. `exec coder ssh "$FLIGHT_WORKSPACE" -- "$@"` |
| `.flight/teardown` | `FLIGHT_WORKSPACE` | — | Optional. Destroy the workspace. |
| `.flight/list` | — | — | Optional. Prints running workspace names, one per line. Populates the "attach to existing" picker. |
| `.flight/monitor` | `FLIGHT_WORKSPACE` | — | Optional. Prints JSON consumed by the Services rail. |

Scripts run via `zsh -l -c` with cwd at the repo root. Each can also be set as a settings-level template (`Settings > Remote`) which overrides the on-disk script for local iteration.

Example `.flight/provision` for Coder:

```bash
#!/usr/bin/env bash
set -euo pipefail
BRANCH="${FLIGHT_BRANCH:?}"
NAME="$(echo "$BRANCH" | tr '/' '-' | tr -cd 'a-z0-9-')"

echo "Creating workspace '$NAME' on branch '$BRANCH'..."
coder create "$NAME" --template my-template --parameter "git_branch=$BRANCH" --yes

# Metadata — Flight strips these from the displayed log and stores them
# on the worktree. Used by the "Open URL" and "Open in VS Code" buttons.
echo "FLIGHT_OUTPUT: url=https://$NAME.example.com"
echo "FLIGHT_OUTPUT: ssh_target=coder.$NAME"
echo "FLIGHT_OUTPUT: repo_path=/home/ubuntu/my-repo"

# Last non-metadata line is captured as the workspace name
echo "$NAME"
```

And `.flight/connect`:

```bash
#!/usr/bin/env bash
exec coder ssh "${FLIGHT_WORKSPACE:?}" -- "$@"
```

### Remote-only projects

A remote-only project has no local clone. You point Flight at a forge repo (GitHub or Forgejo), it downloads the repo's committed `.flight/` scripts, and it uses those to spin up remote workspaces — same contract as Remote workspaces above, just sourced from the forge instead of a local checkout.

1. Click **Add Project** in the sidebar and switch to the **Remote** tab
2. Pick a forge type and enter the repo as `owner/name`, `github.com/owner/name`, or a full URL
3. (Forgejo only) provide the base URL and the env var that holds your API token
4. Hit **Add**. Flight fetches `.flight/provision`, `.flight/connect`, and optional lifecycle scripts like `.flight/teardown`, `.flight/list`, and `.flight/monitor` via `gh api repos/<owner>/<repo>/contents/.flight/<script>` (GitHub) or the Forgejo raw endpoint, caches them under `~/flight/remote-scripts/<name>/`, and adds the project
5. Use **Cmd+Shift+N** to spin up workspaces as normal — there's no Cmd+N flow because there's no local clone to cut worktrees from

Settings-level overrides (**Settings > Remote**) are ignored for remote-only projects. The repo is the source of truth; if you change a script, push to the default branch and re-add the project.

PR/CI features work the same way: Flight calls `gh --repo owner/name` (or the Forgejo REST API) with the owner/repo you provided, so CI checks and reviewer feedback show up without a local checkout.

To have a local and remote-only project for the same repo side by side, add the local one first and rename it in the sheet (or add the remote-only one first — either order works, the collision is surfaced at add time).

### `FLIGHT_OUTPUT` metadata

Provision scripts can emit `FLIGHT_OUTPUT: key=value` lines anywhere in their stream. Flight parses them out (they don't appear in the UI log) and attaches them to the worktree. Recognised keys:

| Key | Purpose |
|---|---|
| `url` | Browser URL for the workspace (web IDE, dashboard). Shows as a link button in the chat header. |
| `ssh_target` | The value that follows `ssh-remote+` for VS Code Remote-SSH (e.g. `coder.my-workspace`, `user@host`). |
| `repo_path` | Path to the repo checkout on the remote workspace. Used by VS Code Remote-SSH to open the right folder. |

Unknown keys are ignored, so the contract is forward-compatible.

### Service monitor

If a project provides `.flight/monitor`, Flight shows a Services rail from the chat header. The script should print JSON only, exit quickly, and avoid long-running tails or watch modes. Flight times out monitor refreshes after 8 seconds. The payload may be either an array of services or an object with a `services` array.

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

`health` is optional and may be `healthy`, `warning`, or `critical`. If omitted, Flight infers health from `status`.

### Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+N | New local worktree (project picker if >1 project) |
| Cmd+Shift+N | New remote worktree (picker over remote-capable projects) |
| Cmd+T | New conversation tab |
| Cmd+W | Close conversation tab (or window if only one tab) |
| Cmd+1-9 | Switch worktrees |
| Cmd+Enter | Restart agent for current worktree |
| Cmd+. | Stop agent |
| Cmd+K | Clear chat |
| Cmd+Shift+R | Open remote session in Terminal (remote worktrees) |
| Cmd+, | Settings |
| Escape | Interrupt agent mid-turn |

### Themes

Flight uses [Base16](https://github.com/tinted-theming/schemes) for theming. Built-in themes:

- System (follows macOS appearance)
- Solarized Dark / Light
- Tokyo Night
- Gruvbox Dark
- Catppuccin Mocha
- Nord

Import any Base16 `.json` theme file via **Settings > General > Import Base16 Theme**. Imported themes are saved to `~/flight/themes/`.

## Architecture

```
Sources/
  FlightApp.swift             App entry, window, keyboard shortcuts
  AppState.swift              Central @Observable state
  Theme.swift                 Base16 theme engine
  Models/
    Project.swift             Repo reference (path optional for remote-only) + remote config
    Worktree.swift            Branch, status, conversations, remote metadata
    Conversation.swift        Per-tab agent session
    AgentMessage.swift        Parsed stream-json messages
    PRStatus.swift            PR review state and decision
    CIStatus.swift            CI check state per worktree
  Services/
    ClaudeAgent.swift         Process lifecycle, stdin/stdout, turn management
    ConfigService.swift       ~/flight/config.json persistence
    GitService.swift          git worktree operations
    ShellService.swift        Async process runner with env/extraArgs support
    RemoteScriptsService.swift Resolves .flight/<script>: on-disk for local, fetched cache for remote-only
    RemoteScriptFetcher.swift Downloads .flight/* from a forge repo for remote-only projects
    WorktreeSetupService.swift Runs .flight/worktree-setup for new local worktrees
    NotificationService.swift  macOS user notifications
  Plugins/
    ForgeProvider.swift       Git hosting abstraction (path-free; owner/repo baked in at construction)
    GitHubForge.swift         Local (gh in repo) + Remote (gh --repo owner/name) impls
    ForgejoForge.swift        Local + Remote Forgejo REST impls
  Views/
    ContentView.swift         Main layout, sheets, error alerts
    SidebarView.swift         Project/worktree list
    ChatView.swift            Message list, header, tool groups
    MessageView.swift         Chat bubbles + tool call rows
    MarkdownText.swift        Lightweight markdown renderer
    InputBarView.swift        Text input, plan mode, stop button
    PasteableTextView.swift   NSTextView wrapper for reliable keyboard handling
    AddProjectSheet.swift     Local/Remote add-project modal
    ProjectPickerSheet.swift  Command-palette project picker for Cmd+N / Cmd+Shift+N
    SettingsView.swift        Themes, font size, worktree setup, remote config
```

### How agents work

Each user message spawns a new `claude -p` process with `--output-format stream-json`. Subsequent messages use `--resume <session_id>` to maintain conversation context. This one-process-per-turn model avoids the complexity of long-lived bidirectional streaming.

**Local**: Process runs directly with the sandbox enabled (filesystem scoped to the worktree, `dangerouslyDisableSandbox` overrides denied).

**Remote**: Flight invokes `zsh -l -c '<connect command>' _ '<remote claude invocation>'` with `FLIGHT_WORKSPACE` set in the environment. Your `.flight/connect` script receives the claude invocation as `"$@"` and SSHes it to the remote workspace. Text-only prompts are base64-encoded through a temp file on the remote for safe shell transport; image turns embed a base64 JSON payload in the remote command, decode it to temporary PNG files on the remote, then prompt Claude with those file paths so it can inspect them through its normal image-aware `Read` path. Remote agents run with `--dangerously-skip-permissions` since the workspace is its own isolation boundary.

### Data storage

All data lives in `~/flight/`:

```
~/flight/
  config.json              Projects, worktrees, remote config
  chat/                    Conversation history (JSON per conversation)
  logs/                    Raw stdin/stdout logs per worktree
  themes/                  Imported Base16 theme files
  worktrees/               Git worktree directories
  remote-scripts/          Cached .flight/* for remote-only projects (one dir per project)
```

## License

MIT
