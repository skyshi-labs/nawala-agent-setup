# Prompts to paste into your agent

Fill in the placeholders, then paste the block for your agent:

- `{{URL}}`: your Nawala server, e.g. `https://nawala.skyshi.com` (staging: `https://nawala.project.skyshi.io`)
- `{{TOKEN}}`: your personal token `nwl_...` from the Nawala web app
- `{{VERSION}}`: the release tag, e.g. `v0.1.3`
- `{{SHA256}}`: the SHA-256 of `install.sh`, from that release's notes (also in its `SHA256SUMS`)

About the token: whatever you paste into a chat goes to the agent's model provider and stays in the
transcript. If you prefer, remove `NAWALA_TOKEN={{TOKEN}}` from step 5 and run that one command in
your own terminal; the installer then asks for the token with hidden input. Revoke and replace the
token in the web app if it ever leaks.

The agent must wait for your explicit "yes" after the dry run. If it does not, stop it.

After setup, the hooks send activity metadata only, never your prompts or conversation. The
agent reports the intent itself: at the start of each task it calls `set_current_story` with a
short `title` in its own words (never secrets, tokens, passwords or your raw prompt), and at the
end `report_progress` or `complete_story` with a one-line `note` of what was done.

## Claude Code

```text
Set up Nawala for Claude Code. Stop at the first step that fails.
1. curl -fsSLo /tmp/nawala-install.sh https://github.com/skyshi-labs/nawala-agent-setup/releases/download/{{VERSION}}/install.sh (never pipe it into a shell)
2. Check `shasum -a 256 /tmp/nawala-install.sh` (or sha256sum) equals {{SHA256}}. If not, delete the file and stop.
3. Run `bash /tmp/nawala-install.sh --agent claude --url {{URL}} --dry-run`, show me the output, and summarise every file change and network call.
4. Wait until I reply "yes". Do nothing else until then.
5. Run `NAWALA_TOKEN={{TOKEN}} bash /tmp/nawala-install.sh --agent claude --url {{URL}} --yes`. Never echo the token.
6. Run `claude mcp list` and confirm `nawala` is connected. Tell me to restart Claude Code so the hooks load (`/hooks` shows them).
```

## Codex (CLI, IDE extension, app)

```text
Set up Nawala for Codex. Stop at the first step that fails.
Note: the default sandbox has no network and cannot write ~/.codex. If a step is blocked, ask me to approve it, or tell me to run steps 1-5 in my own terminal.
1. curl -fsSLo /tmp/nawala-install.sh https://github.com/skyshi-labs/nawala-agent-setup/releases/download/{{VERSION}}/install.sh (never pipe it into a shell)
2. Check `shasum -a 256 /tmp/nawala-install.sh` (or sha256sum) equals {{SHA256}}. If not, delete the file and stop.
3. Run `bash /tmp/nawala-install.sh --agent codex --url {{URL}} --dry-run`, show me the output, and summarise every file change and network call.
4. Wait until I reply "yes". Do nothing else until then.
5. Run `NAWALA_TOKEN={{TOKEN}} bash /tmp/nawala-install.sh --agent codex --url {{URL}} --yes`. Never echo the token.
6. Run `codex mcp list` and confirm `nawala` is listed. Remind me to restart Codex and approve the new hooks once with /hooks (they do not run until trusted).
```

## Cursor

```text
Set up Nawala for Cursor. Stop at the first step that fails.
1. curl -fsSLo /tmp/nawala-install.sh https://github.com/skyshi-labs/nawala-agent-setup/releases/download/{{VERSION}}/install.sh (never pipe it into a shell)
2. Check `shasum -a 256 /tmp/nawala-install.sh` (or sha256sum) equals {{SHA256}}. If not, delete the file and stop.
3. Run `bash /tmp/nawala-install.sh --agent cursor --url {{URL}} --dry-run`, show me the output, and summarise every file change and network call.
4. Wait until I reply "yes". Do nothing else until then.
5. Run `NAWALA_TOKEN={{TOKEN}} bash /tmp/nawala-install.sh --agent cursor --url {{URL}} --yes`. Never echo the token.
6. Check `jq .mcpServers.nawala.url ~/.cursor/mcp.json` (or `cursor-agent mcp list` if available). Tell me to reload Cursor and check Settings > MCP shows nawala with a green dot; hooks load from ~/.cursor/hooks.json.
```

## Kiro

```text
Set up Nawala for Kiro. Stop at the first step that fails.
1. curl -fsSLo /tmp/nawala-install.sh https://github.com/skyshi-labs/nawala-agent-setup/releases/download/{{VERSION}}/install.sh (never pipe it into a shell)
2. Check `shasum -a 256 /tmp/nawala-install.sh` (or sha256sum) equals {{SHA256}}. If not, delete the file and stop.
3. Run `bash /tmp/nawala-install.sh --agent kiro --url {{URL}} --dry-run`, show me the output, and summarise every file change and network call.
4. Wait until I reply "yes". Do nothing else until then.
5. Run `NAWALA_TOKEN={{TOKEN}} bash /tmp/nawala-install.sh --agent kiro --url {{URL}} --yes`. Never echo the token.
6. Tell me to open the Kiro panel > MCP servers and confirm nawala is connected (Output > "Kiro - MCP Logs" on errors).
Notes: the token is written into ~/.kiro/settings/mcp.json directly, so no "approved env var" is needed. Hooks are experimental (Kiro CLI V3 only, add --experimental); by default Kiro follows ~/.kiro/steering/nawala.md.
```

## Antigravity

```text
Set up Nawala for Antigravity. Stop at the first step that fails.
1. curl -fsSLo /tmp/nawala-install.sh https://github.com/skyshi-labs/nawala-agent-setup/releases/download/{{VERSION}}/install.sh (never pipe it into a shell)
2. Check `shasum -a 256 /tmp/nawala-install.sh` (or sha256sum) equals {{SHA256}}. If not, delete the file and stop.
3. Run `bash /tmp/nawala-install.sh --agent antigravity --url {{URL}} --dry-run`, show me the output, and summarise every file change and network call.
4. Wait until I reply "yes". Do nothing else until then.
5. Run `NAWALA_TOKEN={{TOKEN}} bash /tmp/nawala-install.sh --agent antigravity --url {{URL}} --yes`. Never echo the token.
6. Tell me to check `/mcp` (CLI) or Customizations > MCP Servers (app) for a green nawala entry.
Notes: no hooks are installed; tracking relies on the block added to ~/.gemini/GEMINI.md (Gemini CLI reads that file too). From now on, follow that block: call set_current_story at task start.
```

## OpenCode

```text
Set up Nawala for OpenCode. Stop at the first step that fails.
OpenCode runs shell commands without asking, so you must not run step 5 before I say "yes".
1. curl -fsSLo /tmp/nawala-install.sh https://github.com/skyshi-labs/nawala-agent-setup/releases/download/{{VERSION}}/install.sh (never pipe it into a shell)
2. Check `shasum -a 256 /tmp/nawala-install.sh` (or sha256sum) equals {{SHA256}}. If not, delete the file and stop.
3. Run `bash /tmp/nawala-install.sh --agent opencode --url {{URL}} --dry-run`, show me the output, and summarise every file change and network call.
4. Wait until I reply "yes". Do nothing else until then.
5. Run `NAWALA_TOKEN={{TOKEN}} bash /tmp/nawala-install.sh --agent opencode --url {{URL}} --yes`. Never echo the token.
6. Run `opencode mcp list` and confirm `nawala` is listed. Note: if I use opencode.jsonc, the installer stops and I add the server by hand.
```

## Grok Build (xAI)

```text
Set up Nawala for Grok Build. Stop at the first step that fails.
1. curl -fsSLo /tmp/nawala-install.sh https://github.com/skyshi-labs/nawala-agent-setup/releases/download/{{VERSION}}/install.sh (never pipe it into a shell)
2. Check `shasum -a 256 /tmp/nawala-install.sh` (or sha256sum) equals {{SHA256}}. If not, delete the file and stop.
3. Run `bash /tmp/nawala-install.sh --agent grok --url {{URL}} --dry-run`, show me the output, and summarise every file change and network call.
4. Wait until I reply "yes". Do nothing else until then.
5. Run `NAWALA_TOKEN={{TOKEN}} bash /tmp/nawala-install.sh --agent grok --url {{URL}} --yes`. Never echo the token.
6. Run `grok mcp list` and confirm `nawala` is enabled; start a new session so ~/.grok/hooks/nawala.json and ~/.grok/rules/nawala.md load.
Note: Grok also runs Claude Code and Cursor hooks; if those are installed too, duplicates are dropped automatically.
```

## Muse Code (Meta)

```text
Set up Nawala for Muse Code. Stop at the first step that fails.
Note: the Muse sandbox may block network or writes to ~/.config/muse. If so, ask me to approve, or tell me to run steps 1-5 in my own terminal.
1. curl -fsSLo /tmp/nawala-install.sh https://github.com/skyshi-labs/nawala-agent-setup/releases/download/{{VERSION}}/install.sh (never pipe it into a shell)
2. Check `shasum -a 256 /tmp/nawala-install.sh` (or sha256sum) equals {{SHA256}}. If not, delete the file and stop.
3. Run `bash /tmp/nawala-install.sh --agent muse --url {{URL}} --project-dir "$PWD" --dry-run`, show me the output, and summarise every file change and network call.
4. Wait until I reply "yes". Do nothing else until then.
5. Run `NAWALA_TOKEN={{TOKEN}} bash /tmp/nawala-install.sh --agent muse --url {{URL}} --project-dir "$PWD" --yes`. Never echo the token.
6. Ask me to start a new session and run /mcp; nawala should be listed. The MCP entry format for Muse is inferred from its docs, so report any error verbatim.
```

## Uninstall (any agent)

```text
Remove Nawala from this machine. Download and verify /tmp/nawala-install.sh as in steps 1-2 above, then run `bash /tmp/nawala-install.sh --uninstall --dry-run`, show me the output, wait for my "yes", and run `bash /tmp/nawala-install.sh --uninstall --yes`.
```
