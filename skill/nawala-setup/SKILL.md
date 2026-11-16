---
name: nawala-setup
description: Install, verify or remove the Nawala agent setup (MCP server + hooks) for the user's coding agent, using the signed installer from the GitHub release. Use only when the user asks to set up or uninstall Nawala.
license: MIT
allowed-tools: Bash, Read, Grep
---

# Nawala setup

Nawala tracks which story a developer works on. This skill installs the `nawala` MCP server and,
where the agent supports it, lightweight hooks. It never runs anything without the user's "yes".

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

To remove everything: `bash /tmp/nawala-install.sh --uninstall --dry-run`, ask for "yes", then
`bash /tmp/nawala-install.sh --uninstall --yes`.

Network: github.com (download), and the Nawala URL the user gives (`/api/auth/me` during install;
`/v1/events`, `/v1/rules` and `/mcp` afterwards). Nothing else.

Never print, log or store the token, never use sudo, and never edit the agent config files by hand.
