# nawala-agent-setup

[![CI](https://github.com/skyshi-labs/nawala-agent-setup/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/skyshi-labs/nawala-agent-setup/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/skyshi-labs/nawala-agent-setup?label=release)](https://github.com/skyshi-labs/nawala-agent-setup/releases/latest)
[![Signed with Sigstore cosign](https://img.shields.io/badge/signed-Sigstore%20cosign-2e3440?logo=sigstore&logoColor=white)](SECURITY.md#how-to-verify-before-installing)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[![Scanned by Cisco AI Defense skill-scanner](https://img.shields.io/badge/scanned%20by-Cisco%20AI%20Defense%20skill--scanner-049fd9?logo=cisco&logoColor=white)](SECURITY.md#expected-scanner-findings)
[![Scanned by NVIDIA SkillSpector](https://img.shields.io/badge/scanned%20by-NVIDIA%20SkillSpector-76b900?logo=nvidia&logoColor=white)](SECURITY.md#expected-scanner-findings)
[![Semgrep (blocking)](https://img.shields.io/badge/Semgrep-bash%20%2B%20secrets%2C%20blocking-6c39d6?logo=semgrep&logoColor=white)](https://github.com/skyshi-labs/nawala-agent-setup/actions/workflows/ci.yml)
[![ShellCheck (blocking)](https://img.shields.io/badge/ShellCheck-blocking-4eaa25?logo=gnubash&logoColor=white)](https://github.com/skyshi-labs/nawala-agent-setup/actions/workflows/ci.yml)

> Every push and every release runs these checks in CI ([`ci.yml`](.github/workflows/ci.yml)). Semgrep and ShellCheck
> fail the build on a finding; the Cisco AI Defense skill-scanner and NVIDIA SkillSpector run on exactly what an agent
> receives and their reports are attached to each release as `scanner-reports.tar.gz` (expected findings are explained
> in [SECURITY.md](SECURITY.md#expected-scanner-findings)). Each release asset is signed with Sigstore cosign (keyless)
> and listed in `SHA256SUMS`.

Connects AI coding agents to [Nawala](https://nawala.skyshi.com), which tracks what developers work on
with coding agents. One static, versioned, signed shell script:

- adds the `nawala` MCP server (HTTP, `Authorization: Bearer` header) to your agent's user config;
- adds lightweight hooks where the agent supports them (prompt, stop, session start/end; for Claude
  Code also file edits, path only) that send activity metadata only: never prompts or any
  conversation content;
- where the agent has a user-global instruction file, adds a marked block that asks the agent to
  report its intent itself through the Nawala MCP tools (`set_current_story` with a short title in
  its own words, then `report_progress` / `complete_story` with a one-line note).

It edits files in your home directory only, after showing you a diff and asking. `--uninstall`
removes exactly what it added. Everything it can install is in this repo: [`install.sh`](install.sh),
[`hook.sh`](hook.sh), [`templates/`](templates/). See [SECURITY.md](SECURITY.md) for what is changed,
what is sent and how to verify a release.

## Install (one command, in your terminal)

Take `VERSION` and the `install.sh` SHA-256 from the [latest release](https://github.com/skyshi-labs/nawala-agent-setup/releases/latest)
notes (the values below are v0.1.4). Pick your operating system:

**macOS** (Terminal or iTerm; `shasum` is preinstalled):

```sh
VERSION=v0.1.4 SHA256=8e47b6682355d06215d451cc3f08b6c9859cbb2bf684dc4033cdf75d515c3adb
curl -fsSLo nawala-install.sh "https://github.com/skyshi-labs/nawala-agent-setup/releases/download/$VERSION/install.sh" \
  && echo "$SHA256  nawala-install.sh" | shasum -a 256 -c - \
  && bash nawala-install.sh --agent claude --url https://nawala.skyshi.com
```

**Linux** (bash or zsh; `sha256sum` comes with coreutils):

```sh
VERSION=v0.1.4 SHA256=8e47b6682355d06215d451cc3f08b6c9859cbb2bf684dc4033cdf75d515c3adb
curl -fsSLo nawala-install.sh "https://github.com/skyshi-labs/nawala-agent-setup/releases/download/$VERSION/install.sh" \
  && echo "$SHA256  nawala-install.sh" | sha256sum -c - \
  && bash nawala-install.sh --agent claude --url https://nawala.skyshi.com
```

**Windows** (Git Bash from [Git for Windows](https://gitforwindows.org), not PowerShell or CMD; install `jq` first,
e.g. `winget install jqlang.jq`, then reopen Git Bash):

```sh
VERSION=v0.1.4 SHA256=8e47b6682355d06215d451cc3f08b6c9859cbb2bf684dc4033cdf75d515c3adb
curl -fsSLo nawala-install.sh "https://github.com/skyshi-labs/nawala-agent-setup/releases/download/$VERSION/install.sh" \
  && echo "$SHA256  nawala-install.sh" | sha256sum -c - \
  && bash nawala-install.sh --agent claude --url https://nawala.skyshi.com
```

On Windows `~/.nawala` is `C:\Users\<you>\.nawala`. The installer remembers this Git Bash, so the OpenCode plugin can run
`hook.sh` through it.

The installer prints every file it will create or modify (unified diff, token masked) and every
network call, then asks `Apply these changes? [y/N]`. It asks for your token with hidden input
(or reads `NAWALA_TOKEN`). Create a token in the Nawala web app under your profile.

- Several agents: `--agent claude,codex,cursor`; everything installed on this machine: `--agent all-detected`.
- Look first, change nothing: add `--dry-run`.
- Staging: `--url https://nawala.project.skyshi.io`.
- Requirements: macOS, Linux, or Windows with Git Bash; `bash`, `curl`, `jq`. Never run it with `sudo` (it refuses root).

## Update to a new release

No new token is needed: the installer is run again for the agents already installed, with the token and agent list
from `~/.nawala/config`. The same steps, with the current version filled in, are at
<https://nawala.skyshi.com/guide/update>; the dashboard and your agent tell you when your version is behind.

**Recommended: let your agent do it.** Paste this prompt into your agent (Claude Code, Cursor, Codex, OpenCode, ...);
on Windows the agent must run commands in Git Bash:

```text
Update Nawala agent-setup on this machine to v0.1.4. Stop at the first step that fails.
1. Run `grep '^NAWALA_HOOK_VERSION=' ~/.nawala/hook.sh` and `grep -E '^NAWALA_(URL|AGENTS)=' ~/.nawala/config` and show me the output. If ~/.nawala/config does not exist, stop and tell me to follow https://nawala.skyshi.com/guide instead.
2. curl -fsSLo /tmp/nawala-install.sh https://github.com/skyshi-labs/nawala-agent-setup/releases/download/v0.1.4/install.sh (never pipe it into a shell)
3. Check `shasum -a 256 /tmp/nawala-install.sh` (or sha256sum) equals 8e47b6682355d06215d451cc3f08b6c9859cbb2bf684dc4033cdf75d515c3adb. If not, delete the file and stop.
4. Run `NAWALA_TOKEN="$(sed -n 's/^NAWALA_TOKEN=//p' ~/.nawala/config | tail -n 1)" bash /tmp/nawala-install.sh --url https://nawala.skyshi.com --agent "$(sed -n 's/^NAWALA_AGENTS=//p' ~/.nawala/config | tail -n 1)" --dry-run`, show me the output, and summarise every file change and network call.
5. Wait until I reply "yes". Do nothing else until then.
6. Run the same command with --yes instead of --dry-run. Never print the token or the whole ~/.nawala/config.
7. Run `bash /tmp/nawala-install.sh --doctor` and show me the result: hook.sh must be v0.1.4. Then tell me to restart this agent (and resume this chat) so the new hooks load.
```

**Or manually.** The installer shows the diff and asks `Apply these changes? [y/N]`: answer `y`.

macOS (Terminal or iTerm):

```sh
grep '^NAWALA_HOOK_VERSION=' ~/.nawala/hook.sh      # older than the release? update
VERSION=v0.1.4 SHA256=8e47b6682355d06215d451cc3f08b6c9859cbb2bf684dc4033cdf75d515c3adb
curl -fsSLo /tmp/nawala-install.sh "https://github.com/skyshi-labs/nawala-agent-setup/releases/download/$VERSION/install.sh" \
  && echo "$SHA256  /tmp/nawala-install.sh" | shasum -a 256 -c - \
  && NAWALA_TOKEN="$(sed -n 's/^NAWALA_TOKEN=//p' ~/.nawala/config | tail -n 1)" \
     bash /tmp/nawala-install.sh --url https://nawala.skyshi.com --agent "$(sed -n 's/^NAWALA_AGENTS=//p' ~/.nawala/config | tail -n 1)"
bash /tmp/nawala-install.sh --doctor                # hook.sh must show the new version
```

Linux (bash or zsh):

```sh
grep '^NAWALA_HOOK_VERSION=' ~/.nawala/hook.sh      # older than the release? update
VERSION=v0.1.4 SHA256=8e47b6682355d06215d451cc3f08b6c9859cbb2bf684dc4033cdf75d515c3adb
curl -fsSLo /tmp/nawala-install.sh "https://github.com/skyshi-labs/nawala-agent-setup/releases/download/$VERSION/install.sh" \
  && echo "$SHA256  /tmp/nawala-install.sh" | sha256sum -c - \
  && NAWALA_TOKEN="$(sed -n 's/^NAWALA_TOKEN=//p' ~/.nawala/config | tail -n 1)" \
     bash /tmp/nawala-install.sh --url https://nawala.skyshi.com --agent "$(sed -n 's/^NAWALA_AGENTS=//p' ~/.nawala/config | tail -n 1)"
bash /tmp/nawala-install.sh --doctor                # hook.sh must show the new version
```

Windows (Git Bash, not PowerShell or CMD):

```sh
grep '^NAWALA_HOOK_VERSION=' ~/.nawala/hook.sh      # older than the release? update
VERSION=v0.1.4 SHA256=8e47b6682355d06215d451cc3f08b6c9859cbb2bf684dc4033cdf75d515c3adb
curl -fsSLo /tmp/nawala-install.sh "https://github.com/skyshi-labs/nawala-agent-setup/releases/download/$VERSION/install.sh" \
  && echo "$SHA256  /tmp/nawala-install.sh" | sha256sum -c - \
  && NAWALA_TOKEN="$(sed -n 's/^NAWALA_TOKEN=//p' ~/.nawala/config | tail -n 1)" \
     bash /tmp/nawala-install.sh --url https://nawala.skyshi.com --agent "$(sed -n 's/^NAWALA_AGENTS=//p' ~/.nawala/config | tail -n 1)"
bash /tmp/nawala-install.sh --doctor                # hook.sh must show the new version
```

Then restart your agents (and resume open chats). OpenCode: also `opencode service restart` if its background
service runs. Codex: approve the hooks again with `/hooks` if asked.

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
| Claude Code | `~/.claude.json` | prompt, stop, start (+ project rules injected), end, file edits (multi-repo workspaces): `~/.claude/settings.json` | not needed | **Full hooks** |
| Codex (CLI, IDE, app) | `~/.codex/config.toml` | prompt, stop, start (+ rules), end: `~/.codex/hooks.json` (trust once with `/hooks`) | not needed | **Full hooks** |
| Cursor | `~/.cursor/mcp.json` | prompt, stop, start (+ rules), end, file edits (multi-repo workspaces, v0.1.4+): `~/.cursor/hooks.json` | not needed | **Full hooks** |
| Grok Build (xAI) | `~/.grok/config.toml` | prompt, stop, start, end: `~/.grok/hooks/nawala.json` | `~/.grok/rules/nawala.md` | **Partial** (no context injection) |
| Kiro | `~/.kiro/settings/mcp.json` | experimental only (`--experimental`, CLI V3): `~/.kiro/hooks/nawala.json` | `~/.kiro/steering/nawala.md` | **MCP + instructions** |
| Antigravity | `~/.gemini/config/mcp_config.json` | none (no prompt-submit event) | `~/.gemini/GEMINI.md` | **MCP + instructions** |
| OpenCode 2.x | `~/.config/opencode/opencode.json` (`mcp.servers`) | prompt, stop, start, end, file edits through the Nawala plugin `~/.config/opencode/plugins/nawala.js` (v0.1.4+; OpenCode 1.x: none) | `~/.config/opencode/AGENTS.md` | **Full hooks** (no context injection: rules come from AGENTS.md) |
| Muse Code (Meta) | `~/.config/muse/settings.json` (shape inferred, `mode: optional`) | none (format undocumented) | `<repo>/AGENTS.md` with `--project-dir <repo>` | **MCP + instructions** (unverified) |

"Full hooks" means Nawala sees when each prompt is submitted and each turn finishes, session
start/end, the agent's model (and effort level where the agent reports it) and the commits made in
between, without the agent doing anything. The hooks never send the prompt text or any other
conversation content (see [SECURITY.md](SECURITY.md#what-is-sent-and-where)): what the work is
about comes only from the agent's own `set_current_story` / `report_progress` / `complete_story`
calls. "MCP + instructions" relies on the agent following the instruction block and calling the
MCP tools.

## Which repos are tracked

Work repos only. The hooks send something only when the repo's git remote matches your
organisation's client rules or a repo of a project you are a member of. The hook fetches that list
from the server (`GET /v1/tracking`, cached 15 minutes in `~/.nawala/tracking.json`) and decides on
your machine, so personal and internal repos are never sent, not even their name. The same list
holds the local folders you linked to a project: a repo (or, from v0.1.3, a folder that is not a git
repo) inside a linked folder is tracked too. A folder without a git remote is tracked only through
such a link, and when the list cannot be fetched and there is no cached copy, nothing is sent.

- Opt one repo out: `git config nawala.off true` (inside that repo).
- Pause everything: `export NAWALA_OFF=1`.

### "Terhubung sebagian" on the dashboard? Run the doctor

`bash install.sh --doctor` (read-only) shows the installed hook.sh version (an outdated one is
flagged), whether jq/curl/git are found, which agents have hooks registered, and what each agent's
hook did last time it ran, e.g. `stop -> untracked` (the folder is not a work repo and not linked)
or `prompt -> sent:202`. Every hook run (v0.1.4+) records that one line, and nothing else, in
`~/.nawala/state/last-run-<agent>`. The doctor's only network call is `GET <url>/api/auth/me`.

The dashboard says "Terhubung penuh" once any hook has talked to the server in the last 14 days,
and "Terhubung sebagian" when only the MCP token was used. Typical causes of "sebagian":

- an old hook.sh (before v0.1.3 a session that starts outside a git repo, e.g. a parent folder
  with several repos, sent nothing at all, not even the check-in): re-run the installer;
- OpenCode before v0.1.4 had no hooks at all: re-run the installer, then restart OpenCode
  (`opencode service restart` when the background service runs);
- Codex: the hooks were never approved with `/hooks`;
- the agent was not restarted after the install.

### Chats that were already open

The hooks only see sessions that start after the install. Restart (or resume) chats that were
already running. Nothing is backfilled: earlier turns are not sent, and chat content never is.

### Multi-repo workspaces (Claude Code v0.1.3+, Cursor and OpenCode v0.1.4+)

You open a workspace folder that is not a git repo and add the repos as additional working
directories (e.g. `D:\Work\Client` with `api/` and `web/` inside it):

- Each turn is recorded under the linked repo the agent last edited (with Edit/Write), and on stop
  the new commits are sent per edited repo.
- The prompt of a turn before any edit is recorded only if the workspace folder itself is linked
  with `scope=parent`. A parent link covers every repo beneath it, so link the workspace folder,
  not a shared parent that also holds personal repos.
- Commits made only through Bash in a repo the agent never edited with Edit/Write are not picked up.
- Claude Code (`PostToolUse`), Cursor (`afterFileEdit`) and OpenCode (the plugin's edit-tool hook).
  Existing installs: re-run the installer once to add the file-edit entry.
- Privacy: Claude's `PostToolUse` input contains the edited file's contents. The hook reads only the
  file path from it, to find that file's git root. Nothing from that input is sent or stored, except
  the root folder of a tracked repo, locally in `~/.nawala/state/`.

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
Stop tracking one repo: `git config nawala.off true` in that repo.

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
