# nawala-agent-setup

Connects AI coding agents to [Nawala](https://nawala.skyshi.com), which tracks what developers work on
with coding agents. One static, versioned, signed shell script:

- adds the `nawala` MCP server (HTTP, `Authorization: Bearer` header) to your agent's user config;
- adds lightweight hooks where the agent supports them (prompt, stop, session start/end);
- for agents without reliable hooks, adds a marked block to the user-global instruction file that
  asks the agent to call the Nawala MCP tools (`set_current_story`, `report_progress`, `complete_story`).

It edits files in your home directory only, after showing you a diff and asking. `--uninstall`
removes exactly what it added. Everything it can install is in this repo: [`install.sh`](install.sh),
[`hook.sh`](hook.sh), [`templates/`](templates/). See [SECURITY.md](SECURITY.md) for what is changed,
what is sent and how to verify a release.

## Install (one command, in your terminal)

Take `VERSION` and the `install.sh` SHA-256 from the [latest release](https://github.com/skyshi-labs/nawala-agent-setup/releases/latest) notes:

```sh
VERSION=v0.1.0 SHA256=<sha256 of install.sh from the release notes>
curl -fsSLo nawala-install.sh "https://github.com/skyshi-labs/nawala-agent-setup/releases/download/$VERSION/install.sh" \
  && echo "$SHA256  nawala-install.sh" | shasum -a 256 -c - \
  && bash nawala-install.sh --agent claude --url https://nawala.skyshi.com
```

(`shasum` is preinstalled on macOS; on Linux use `sha256sum -c -` instead.)

The installer prints every file it will create or modify (unified diff, token masked) and every
network call, then asks `Apply these changes? [y/N]`. It asks for your token with hidden input
(or reads `NAWALA_TOKEN`). Create a token in the Nawala web app under your profile.

- Several agents: `--agent claude,codex,cursor`; everything installed on this machine: `--agent all-detected`.
- Look first, change nothing: add `--dry-run`.
- Staging: `--url https://nawala.project.skyshi.io`.
- Requirements: macOS or Linux, `bash`, `curl`, `jq`. Never run it with `sudo` (it refuses root).

## Install from inside your agent

Paste the prompt for your agent from [PROMPTS.md](PROMPTS.md) (fill in `{{URL}}`, `{{TOKEN}}`,
`{{VERSION}}`, `{{SHA256}}`). The agent downloads the release asset, checks the SHA-256, shows
you the dry run, waits for your "yes", installs, and checks the MCP connection.

Generic prompt:

```text
Set up Nawala for this coding agent. Stop at the first step that fails.
1. Download https://github.com/skyshi-labs/nawala-agent-setup/releases/download/{{VERSION}}/install.sh to /tmp/nawala-install.sh (curl -fsSLo; do not pipe it into a shell).
2. Compute its SHA-256 (shasum -a 256 or sha256sum). It must equal {{SHA256}}; otherwise delete it and stop.
3. Run: bash /tmp/nawala-install.sh --agent <this agent> --url {{URL}} --dry-run. Show me the output and summarise each file change and network call.
4. Wait for me to reply "yes". Do nothing until then.
5. Run: NAWALA_TOKEN={{TOKEN}} bash /tmp/nawala-install.sh --agent <this agent> --url {{URL}} --yes. Never echo the token.
6. Verify the nawala MCP server with this agent's MCP list command and tell me the result.
```

## Support matrix

| Agent | MCP server | Hooks | Instruction block | Level |
|---|---|---|---|---|
| Claude Code | `~/.claude.json` | prompt, stop, start (+ project rules injected), end: `~/.claude/settings.json` | not needed | **Full hooks** |
| Codex (CLI, IDE, app) | `~/.codex/config.toml` | prompt, stop, start (+ rules), end: `~/.codex/hooks.json` (trust once with `/hooks`) | not needed | **Full hooks** |
| Cursor | `~/.cursor/mcp.json` | prompt, stop, start (+ rules), end: `~/.cursor/hooks.json` | not needed | **Full hooks** |
| Grok Build (xAI) | `~/.grok/config.toml` | prompt (no prompt text), stop, start, end: `~/.grok/hooks/nawala.json` | `~/.grok/rules/nawala.md` | **Partial** (no prompt text, no context injection) |
| Kiro | `~/.kiro/settings/mcp.json` | experimental only (`--experimental`, CLI V3): `~/.kiro/hooks/nawala.json` | `~/.kiro/steering/nawala.md` | **MCP + instructions** |
| Antigravity | `~/.gemini/config/mcp_config.json` | none (no prompt-submit event) | `~/.gemini/GEMINI.md` | **MCP + instructions** |
| OpenCode | `~/.config/opencode/opencode.json` (`mcp.servers`) | none (plugin API is changing) | `~/.config/opencode/AGENTS.md` | **MCP + instructions** |
| Muse Code (Meta) | `~/.config/muse/settings.json` (shape inferred, `mode: optional`) | none (format undocumented) | `<repo>/AGENTS.md` with `--project-dir <repo>` | **MCP + instructions** (unverified) |

"Full hooks" means Nawala sees each prompt, each finished turn, session start/end and the commits
made in between, without the agent doing anything. "MCP + instructions" relies on the agent
following the instruction block and calling the MCP tools.

## Uninstall

```sh
bash nawala-install.sh --uninstall --dry-run   # see what would be restored or removed
bash nawala-install.sh --uninstall             # all agents
bash nawala-install.sh --uninstall --agent codex
```

Every file the installer touched is backed up first (`~/.nawala/backups/`). If a file is unchanged
since the installer wrote it, uninstall restores the original byte-for-byte (mode included).
If you or the agent changed it since, uninstall removes only the Nawala entries and keeps the rest.
The last uninstall also removes `~/.nawala`.

Pause tracking without uninstalling: `export NAWALA_OFF=1` (hooks exit immediately and send nothing).

## Development

```sh
tests/run.sh                         # plain bash, temp HOME per test, fake curl, no network or docker
scripts/build-release.sh dist        # self-contained dist/install.sh + hook.sh + templates.tar.gz + SHA256SUMS
NAWALA_INSTALL_SH=$PWD/dist/install.sh tests/run.sh install
shellcheck install.sh hook.sh scripts/*.sh tests/*.sh tests/bin/curl
```

`install.sh` in the repo reads `hook.sh` and `templates/` from disk. The release build embeds them
verbatim (quoted heredocs, no encoding) so a single SHA-256 covers everything that gets installed;
`install.sh --print-file hook.sh` prints the embedded copy for comparison.

Releases: push a tag `vX.Y.Z` matching `NAWALA_SETUP_VERSION` in `install.sh`. The release workflow
runs the tests and scanners, builds the assets, signs each with Sigstore cosign (keyless), and
publishes them with the scanner reports.

## License

MIT, see [LICENSE](LICENSE).
