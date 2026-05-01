# Panels (proposal)

> Status: design sketch, not yet implemented. The protocol below is the
> proposed v1 — feedback welcome before any code lands.

A **panel** is a long-running script that streams a constrained UI tree to
Flight's right-hand pane. The goal is to let users build live dashboards
(container status, CI feeds, queue depth, deploy state, anything tail-able)
without writing Swift, while keeping Flight's visual language consistent.

The contract mirrors the existing `.flight/` lifecycle scripts: shell
process, stdout-as-protocol, no Flight-specific runtime to install.

**Panels are output-only.** They render. They do not receive callbacks.
The single form of interactivity is a button or row action that pre-fills
the chat input with a prompt — the user reviews, sends, and Claude does
the actuating. Anything mutating routes through the conversation where
the user already has review, undo, and history. Panels can never
half-build a form or a confirmation dialog because the protocol won't
let them.

## Concepts

**Panel** — one executable script in `.flight/panels/<name>`. Each becomes
a tab in the right-hand pane. The filename is the stable identifier; the
display title comes from a `title` event (or falls back to the filename).

**Tree** — the current UI state, a JSON node graph the panel emits and
re-emits over time. Flight diffs against the previous tree and renders.

**Action** — a user gesture (button click, row tap) that pre-fills the
chat input with a prompt the panel attached. The panel itself is not
notified.

## Discovery & precedence

Same shape as the remote lifecycle scripts:

1. `<project.path>/.flight/panels/<name>` — committed to the repo, shared
   by the team.
2. `project.panels[<name>]` in `~/flight/config.json` — a settings-level
   override (single shell command string), useful for prototyping without
   committing.
3. For remote-only projects: cached at
   `~/flight/remote-scripts/<projectName>/panels/<name>`, refreshed in the
   background like the rest of `.flight/`.

A project can ship any number of panels. Panels are opt-in per user — the
first time a panel is detected, Flight surfaces it as a chip the user
clicks to enable. Panels never auto-run without consent.

## Process model

When a panel becomes visible, Flight spawns it via `/bin/zsh -l -c`.

**Environment:**

| Var | Set when | Description |
|---|---|---|
| `FLIGHT_PANEL` | always | Panel name (filename). |
| `FLIGHT_PROJECT_PATH` | always | Repo root on disk (local projects only). |
| `FLIGHT_WORKTREE_PATH` | always (local) | The currently selected worktree. |
| `FLIGHT_BRANCH` | always | Current branch. |
| `FLIGHT_WORKSPACE` | remote worktrees | Workspace name. |

**cwd:** the worktree path for local worktrees, the repo root otherwise.

**Lifetime:** the panel runs as long as it is visible. Flight sends
`SIGTERM` (then `SIGKILL` after 2s) when the user hides the pane, switches
worktrees, or quits. A "Reload" affordance restarts the process. The
script is expected to be idempotent on restart.

**stdout:** newline-delimited JSON (NDJSON), one event per line. Lines
that fail to parse are logged to Flight's debug log and ignored — so
`set -x` or stray `echo`s don't kill the panel.

**stdin:** unused. Closed by Flight. Reserved for future protocol
expansion — see [Out of scope for v1](#out-of-scope-for-v1).

**stderr:** surfaced in a panel-scoped log drawer the user can open. Not
parsed.

## Render protocol (script → Flight)

Two ops change the tree:

```jsonc
// Replace the entire panel.
{"op":"replace","tree": <node>}

// Patch one subtree by id (the node and all its descendants are swapped).
{"op":"patch","id":"web-1","node": <node>}
```

Side-effect ops do not change the tree:

```jsonc
{"op":"title","text":"Docker"}                          // tab label
{"op":"toast","level":"info","message":"Restarted web"} // ephemeral
{"op":"error","message":"docker not on PATH"}           // sticky banner
{"op":"clear_error"}
```

A panel that emits no events within 1s of starting renders a "Loading…"
placeholder. A panel that exits with no tree shows its stderr.

## Node types (v1)

Seven primitives, deliberately minimal:

```jsonc
// Group with a heading and children.
{"type":"section","title":"Containers","children":[...]}

// One line of content. The most common building block.
{"type":"row",
 "id":"web-1",
 "title":"web-1",
 "subtitle":"nginx · running 3d",
 "status":"ok",                    // ok | warn | error | gray
 "actions":[{"label":"Restart","prompt":"Restart container web-1"}]}

// Key/value table. Right-aligned values.
{"type":"kv","items":[
  {"key":"Uptime","value":"3d 4h"},
  {"key":"Restarts","value":"0"}]}

// Single status pill.
{"type":"status","label":"API","value":"healthy","color":"green"}
// color: green | yellow | red | gray

// Big-number metric with optional trend arrow.
{"type":"metric","label":"Req/s","value":"142","trend":"up"}
// trend: up | down | flat | omitted

// Tail of monospaced text. follow=true autoscrolls; max caps in-memory lines.
{"type":"log","lines":["12:01 GET /","12:01 GET /api"],"follow":true,"max":500}

// Standalone action.
{"type":"button","label":"Reload all","prompt":"Reload all containers","style":"default"}
// style: default | destructive
```

Every node accepts an optional `id`. `patch` requires it.

**Forward compatibility:** unknown `type` values render as a placeholder
("Unknown widget: foo — update Flight?") and a debug-log warning.
Unknown fields on known types are ignored. This mirrors the existing
`FLIGHT_OUTPUT` rule and lets new widgets ship without breaking old
clients.

## Actions

Buttons and row actions carry a `label` and a `prompt`. When the user
activates one, Flight inserts the prompt text into the chat input — it
does not auto-send. The user reviews, edits if needed, and submits the
turn themselves. Claude does the actuating; the panel observes the
resulting state on its next render tick.

```json
{"label":"Restart","prompt":"Restart container web-1"}
```

That's the entire action surface. No callbacks, no return values, no
synchronisation between panel and conversation. If the panel needs to
reflect that something happened, it picks it up the next time it polls
its underlying source of truth.

This deliberately makes every mutation LLM-mediated. A "Restart" button
costs an LLM round-trip to run a one-line command — slower than a direct
call and a few tokens of cost. The benefit is that every action lands in
chat history with full context, the user can intercept before it runs,
and the panel author writes zero confirmation/error/undo UI.

## Example: docker

```bash
#!/usr/bin/env bash
# .flight/panels/docker — list containers, click to ask Claude.
set -u

emit() { printf '%s\n' "$1"; }

emit '{"op":"title","text":"Docker"}'

while true; do
  rows=$(docker ps -a --format '{{json .}}' 2>/dev/null | jq -s '[.[] | {
    type: "row",
    id: .ID,
    title: .Names,
    subtitle: "\(.Image) · \(.Status)",
    status: (if (.State == "running") then "ok" else "gray" end),
    actions: [
      {label:"Restart", prompt:"Restart container \(.Names)"},
      {label:"Stop",    prompt:"Stop container \(.Names)"}
    ]
  }]')
  tree=$(jq -cn --argjson c "${rows:-[]}" \
    '{type:"section", title:"Containers", children:$c}')
  emit "{\"op\":\"replace\",\"tree\":$tree}"
  sleep 2
done
```

A user drops this in `.flight/panels/docker`, makes it executable, and
gets a live container list in their right pane. Clicking "Restart" on a
row pre-fills the chat with `Restart container web-1`; the user hits
send, Claude runs `docker restart`, and the panel's next 2s tick reflects
the new status.

The Flight repo itself ships a working read-only example at
`.flight/panels/git` — current branch, modified files, recent commits,
refreshed every 2s. Cut a worktree from Flight and the panel toggle
appears in the chat header automatically. Read it as a reference for the
shape of a real panel script.

## Out of scope for v1

Deliberately excluded to keep the surface small:

- **Stdin callbacks.** Panels are output-only. Anything mutating goes
  through the chat-prompt action mechanism. If we later need a direct
  channel for high-frequency or non-LLM-suitable actions, stdin is the
  obvious extension point — that's why it's reserved rather than
  repurposed.
- **Auto-sent turns.** Action prompts pre-fill the input; the user sends.
  Letting a panel fire LLM turns on its own is a cost/safety question
  worth its own design.
- **Charts / sparklines.** Defer until the row/metric primitives have
  shaken out.
- **Forms / text input.** Buttons + row actions only. If a panel needs
  free-form input, it asks via a prompt and lets Claude collect details
  in chat.
- **Custom theming or arbitrary colors.** Status colors are a fixed
  palette so panels stay visually consistent with the rest of Flight.
- **HTML / WebView escape hatch.** Once shipped, nobody writes native
  primitives. The constraint is the point.
- **Multi-pane layout.** One panel = one tree. Users open multiple panel
  tabs if they want multiple views.

These can land in v2 once v1 has real users.
