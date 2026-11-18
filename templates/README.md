# templates

Snippets `install.sh` merges into each agent's user config. Placeholders, filled in by `install.sh`:

- `__NAWALA_MCP_URL__`: `<url>/mcp?agent=<folder name>` (lets the server attribute MCP-only sessions to the agent)
- `__NAWALA_AUTH__`: `Bearer <token>` (JSON: the whole string value; TOML: inside the quotes)
- `__NAWALA_URL__`: the server URL (instruction text only)
- `__NAWALA_HOOK__`: absolute path of `~/.nawala/hook.sh`
- `__NAWALA_HOOK_JSON__` / `__NAWALA_BASH_JSON__` (JavaScript, `opencode/plugin.js`): the hook path
  and, on Windows (Git Bash), the `bash.exe` the installer ran under, as JSON strings ("" elsewhere)

JSON fragments are merged with `jq` (other entries kept). TOML fragments are appended between
`# nawala:start` / `# nawala:end`. Markdown blocks go between `<!-- nawala:start -->` /
`<!-- nawala:end -->`. Verified = checked against the agent's official docs on 2026-11-16.

## claude (Claude Code)
- `claude/mcp.json` -> `~/.claude.json` at `mcpServers.nawala`. Verified (`type: http`, `headers`).
- `claude/hooks.json` -> `~/.claude/settings.json` under `hooks` (one matcher group per event,
  `timeout` in seconds). Verified. `SessionStart` output: `hookSpecificOutput.additionalContext`.
  `PostToolUse` (matcher `Edit|Write|MultiEdit|NotebookEdit`, 5 s) runs `hook.sh touch`: it reads
  only `tool_input.file_path` / `notebook_path` to note which tracked repo the session edits
  (multi-repo workspaces, hook v0.1.3+).

## codex (Codex CLI, IDE extension, app)
- `codex/mcp.toml` -> `~/.codex/config.toml`. Verified keys `url`, `http_headers`.
- `codex/hooks.json` -> `~/.codex/hooks.json` under `hooks`. Verified shape and `timeout` (seconds);
  `SessionEnd` allows at most 3 s. Hooks must be trusted once with `/hooks`.

## cursor
- `cursor/mcp.json` -> `~/.cursor/mcp.json` at `mcpServers.nawala`. Verified (`url`, `headers`).
- `cursor/hooks.json` -> `~/.cursor/hooks.json` (`version: 1`, flat `{command, timeout}` entries).
  Verified. `sessionStart` output: `additional_context`; `beforeSubmitPrompt` answers `{"continue":true}`.
  `afterFileEdit` (5 s) runs `hook.sh touch`: it reads only the top-level `file_path` (hook v0.1.4+).

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
  the current schema (`type: remote`, `headers`, `oauth`; no `enabled` key). Checked on 2.3.0.
- `opencode/plugin.js` -> `~/.config/opencode/plugins/nawala.js` (whole file), OpenCode 2.x only
  (`opencode --version`, run with a throw-away HOME). OpenCode 2 plugin API (`export default {id,
  setup(ctx)}`), verified on 2.3.0: `session.hook("prompt")` -> prompt (first one also -> start),
  events `session.execution.succeeded|failed|interrupted` -> stop, `session.created` -> start,
  `session.deleted` -> end, `tool.hook("execute.after")` for write/edit/apply_patch -> touch. It
  starts `hook.sh` with `{sessionID, directory, model, prompt_id | turn_id | tool_input.file_path}` on
  stdin; never the prompt text. Limitation: `opencode run --standalone` exits right after the turn,
  so its final stop may be lost (the TUI, desktop app and background service are not affected).
- `instructions.md` -> block in `~/.config/opencode/AGENTS.md`.

## grok (Grok Build, xAI)
- `grok/mcp.toml` -> `~/.grok/config.toml`. Verified keys `url`, `enabled`, `headers`.
- `grok/hooks.json` -> `~/.grok/hooks/nawala.json`. Verified shape; no context injection is
  documented.
- `grok/rules.md` -> `~/.grok/rules/nawala.md`. Verified directory.

## muse (Muse Code, Meta)
- `muse/mcp.json` -> `~/.config/muse/settings.json` at `mcp_servers.nawala` (file gets
  `schema_version: 1` if new). PARTLY VERIFIED: the keys are documented, the exact
  `streamable_http` example is not. `mode: optional` so a failure never blocks Muse.
- `instructions.md` -> block in `<dir>/AGENTS.md` with `--project-dir <dir>` (no documented
  user-global instruction file).

## instructions.md
The instruction block (also the body of `kiro/steering.md` and `grok/rules.md`). Hooks send
activity metadata only, never prompts, so the intent comes from the agent: `set_current_story`
with a short `title` in its own words (plus `remote`, `model`, `effort`) at task start, and
`report_progress` / `complete_story` with a one-line `note` at the end. Never secrets or the raw prompt.
