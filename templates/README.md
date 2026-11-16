# templates

Snippets `install.sh` merges into each agent's user config. Placeholders, filled in by `install.sh`:

- `__NAWALA_MCP_URL__`: `<url>/mcp`
- `__NAWALA_AUTH__`: `Bearer <token>` (JSON: the whole string value; TOML: inside the quotes)
- `__NAWALA_URL__`: the server URL (instruction text only)
- `__NAWALA_HOOK__`: absolute path of `~/.nawala/hook.sh`

JSON fragments are merged with `jq` (other entries kept). TOML fragments are appended between
`# nawala:start` / `# nawala:end`. Markdown blocks go between `<!-- nawala:start -->` /
`<!-- nawala:end -->`. Verified = checked against the agent's official docs on 2026-11-16.

## claude (Claude Code)
- `claude/mcp.json` -> `~/.claude.json` at `mcpServers.nawala`. Verified (`type: http`, `headers`).
- `claude/hooks.json` -> `~/.claude/settings.json` under `hooks` (one matcher group per event,
  `timeout` in seconds). Verified. `SessionStart` output: `hookSpecificOutput.additionalContext`.

## codex (Codex CLI, IDE extension, app)
- `codex/mcp.toml` -> `~/.codex/config.toml`. Verified keys `url`, `http_headers`.
- `codex/hooks.json` -> `~/.codex/hooks.json` under `hooks`. Verified shape and `timeout` (seconds);
  `SessionEnd` allows at most 3 s. Hooks must be trusted once with `/hooks`.

## cursor
- `cursor/mcp.json` -> `~/.cursor/mcp.json` at `mcpServers.nawala`. Verified (`url`, `headers`).
- `cursor/hooks.json` -> `~/.cursor/hooks.json` (`version: 1`, flat `{command, timeout}` entries).
  Verified. `sessionStart` output: `additional_context`; `beforeSubmitPrompt` answers `{"continue":true}`.

## kiro
- `kiro/mcp.json` -> `~/.kiro/settings/mcp.json` at `mcpServers.nawala`. Verified (`url`, `headers`;
  token inlined because Kiro only expands approved env vars).
- `kiro/steering.md` -> `~/.kiro/steering/nawala.md` (whole file, `inclusion: always`). Verified.
- `kiro/hooks.experimental.json` -> `~/.kiro/hooks/nawala.json`, only with `--experimental`.
  UNVERIFIED: file shape built from the documented field list; payloads for CLI V3 undocumented.

## antigravity (Google Antigravity)
- `antigravity/mcp.json` -> `~/.gemini/config/mcp_config.json` at `mcpServers.nawala`. Verified
  (`serverUrl`, `headers`). No hooks: there is no prompt-submit event.
- `instructions.md` -> block in `~/.gemini/GEMINI.md`. Verified path.

## opencode
- `opencode/mcp.json` -> `~/.config/opencode/opencode.json` at `mcp.servers.nawala`. Verified against
  the current schema (`type: remote`, `headers`, `oauth`; no `enabled` key). No plugin is shipped.
- `instructions.md` -> block in `~/.config/opencode/AGENTS.md`.

## grok (Grok Build, xAI)
- `grok/mcp.toml` -> `~/.grok/config.toml`. Verified keys `url`, `enabled`, `headers`.
- `grok/hooks.json` -> `~/.grok/hooks/nawala.json`. Verified shape; no prompt text and no context
  injection are documented, so prompt events carry no text.
- `grok/rules.md` -> `~/.grok/rules/nawala.md`. Verified directory.

## muse (Muse Code, Meta)
- `muse/mcp.json` -> `~/.config/muse/settings.json` at `mcp_servers.nawala` (file gets
  `schema_version: 1` if new). PARTLY VERIFIED: the keys are documented, the exact
  `streamable_http` example is not. `mode: optional` so a failure never blocks Muse.
- `instructions.md` -> block in `<dir>/AGENTS.md` with `--project-dir <dir>` (no documented
  user-global instruction file).

## instructions.md
The block for agents without reliable hooks: call `set_current_story` at task start,
`report_progress` after meaningful steps, `complete_story` at the end.
