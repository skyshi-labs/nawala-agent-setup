---
name: nawala-setup
description: Install, verify or remove the Nawala agent setup (MCP server + hooks) for the user's coding agent, using the signed installer from the GitHub release. Use only when the user asks to set up or uninstall Nawala.
license: MIT
allowed-tools: Bash, Read, Grep
---

# Nawala setup

Nawala tracks which story a developer works on. This skill installs the `nawala` MCP server and,
where the agent supports it, lightweight hooks that send activity metadata only (never prompts or
conversation content). It never runs anything without the user's "yes".

Inputs the user must give you: the Nawala URL (`https://...`), the release version (`vX.Y.Z`),
the expected SHA-256 of `install.sh`, and the agent name. The token is entered by the user only.

1. Download the installer from the release (no piping into a shell):
   `curl -fsSLo /tmp/nawala-install.sh https://github.com/skyshi-labs/nawala-agent-setup/releases/download/<version>/install.sh`
2. Verify it: `shasum -a 256 /tmp/nawala-install.sh` (or `sha256sum`). If the hash is not exactly the
   one the user gave you, stop, delete the file and tell the user.
3. Show the plan: `bash /tmp/nawala-install.sh --agent <agent> --url <url> --dry-run` and summarise
   every file it will create or modify and every network call.
4. Ask the user to reply "yes". Do nothing else until they do.
5. Ask the user to run the install themselves in a terminal, so the token stays out of the chat:
   `NAWALA_TOKEN=<token> bash /tmp/nawala-install.sh --agent <agent> --url <url> --yes`
   (or without `NAWALA_TOKEN`, so the installer asks for it with hidden input).
6. Verify with the agent's MCP list command and report the result.
7. Tell the user that chats already running before the install must be restarted or resumed
   before their hooks fire. There is no backfill: earlier turns and chat content are never sent.

Multi-repo workspaces (Claude Code only, hook v0.1.3+): when the start folder is not a git repo and
the repos are opened as additional working directories, tell the user:
- each turn is recorded under the linked repo the agent last edited with Edit/Write, and on stop
  the new commits are sent per edited repo;
- the prompt of a turn before any edit is recorded only if the workspace folder itself is linked
  with `scope=parent`; a parent link covers every repo beneath it, so link the workspace folder,
  not a shared parent that also holds personal repos;
- commits made only through Bash in a repo never edited with Edit/Write are not picked up;
- an existing install must re-run the installer to get the `PostToolUse` (file edit) hook.
Privacy: the `PostToolUse` input contains file contents; the hook reads only the file path to find
the git root. Nothing from it is sent or stored, except the root folder of a tracked repo, locally.

After setup, report intent yourself on every task: at the start call `set_current_story` with a
short `title` stating the intent in your own words (plus `model` / `effort` if you know them), at
the end `report_progress` or `complete_story` with a one-line `note`. Never put secrets, tokens,
passwords or the user's raw prompt in them.

To remove everything: `bash /tmp/nawala-install.sh --uninstall --dry-run`, ask for "yes", then
`bash /tmp/nawala-install.sh --uninstall --yes`.

Network: github.com (download), and the Nawala URL the user gives (`/api/auth/me` during install;
`/v1/tracking`, `/v1/events`, `/v1/rules` and `/mcp` afterwards). Nothing else.

Never print, log or store the token, never use sudo, and never edit the agent config files by hand.
