# Security

This repo installs software that sends data about your coding sessions to a Nawala server, so it is
built to be audited: one static bash script per role, no server-side templating, no runtime
downloads, signed releases, and a dry run that shows every change before it happens.

## What is installed and changed

Everything goes into your home directory. No root, no `sudo` (the installer refuses to run as
root), no system files, no shell profile edits, no background services, no cron jobs.

Always:

| Path | What |
|---|---|
| `~/.nawala/config` (0600) | `NAWALA_URL`, `NAWALA_TOKEN`, `NAWALA_AGENTS` |
| `~/.nawala/hook.sh` (0700) | the `hook.sh` of the release, embedded in `install.sh` (never downloaded) |
| `~/.nawala/manifest.tsv`, `~/.nawala/backups/` | what was changed + the original files, for `--uninstall` |
| `~/.nawala/state/`, `~/.nawala/rules/`, `~/.nawala/tracking.json`, `~/.nawala/spool.jsonl` | created later by the hook: per-session last HEAD, dedupe keys, cached project rules, cached list of tracked repo prefixes, events waiting for the server (max 10 MB) |

Per agent (only for the agents you pass with `--agent`):

| Agent | Files | Change |
|---|---|---|
| Claude Code | `~/.claude.json` | `mcpServers.nawala` (type http, url, Authorization header) |
| | `~/.claude/settings.json` | one entry each in `hooks.UserPromptSubmit`, `Stop`, `SessionStart`, `SessionEnd` running `~/.nawala/hook.sh <mode> --agent claude` |
| Codex | `~/.codex/config.toml` | `[mcp_servers.nawala]` between `# nawala:start` / `# nawala:end` |
| | `~/.codex/hooks.json` | same four hook events (Codex asks you to trust them via `/hooks`) |
| Cursor | `~/.cursor/mcp.json` | `mcpServers.nawala` |
| | `~/.cursor/hooks.json` | `beforeSubmitPrompt`, `stop`, `sessionStart`, `sessionEnd` |
| Kiro | `~/.kiro/settings/mcp.json` | `mcpServers.nawala` |
| | `~/.kiro/steering/nawala.md` | new file: instruction block (`inclusion: always`) |
| | `~/.kiro/hooks/nawala.json` | only with `--experimental` |
| Antigravity | `~/.gemini/config/mcp_config.json` | `mcpServers.nawala` (`serverUrl`) |
| | `~/.gemini/GEMINI.md` | block between `<!-- nawala:start -->` / `<!-- nawala:end -->` |
| OpenCode | `~/.config/opencode/opencode.json` | `mcp.servers.nawala` (type remote) |
| | `~/.config/opencode/AGENTS.md` | marked block |
| Grok Build | `~/.grok/config.toml` | `[mcp_servers.nawala]` between markers |
| | `~/.grok/hooks/nawala.json` | new file: four hook events |
| | `~/.grok/rules/nawala.md` | new file: instruction block |
| Muse Code | `~/.config/muse/settings.json` | `mcp_servers.nawala` (`streamable_http`, `mode: optional`) |
| | `<dir>/AGENTS.md` | marked block, only with `--project-dir <dir>` |

Rules the installer follows: back up each file before its first change; merge, never overwrite
(other MCP servers, hooks and settings are kept; JSON is edited with `jq`, TOML and Markdown only
inside the markers); refuse to touch a file it cannot parse (e.g. JSON with comments) or that
already has a `nawala` entry it did not create; do nothing when everything is already installed.
The token is written into each MCP config because several agents cannot expand environment
variables in headers (Kiro needs per-variable approval, Antigravity reportedly does not expand
them); those files are made private (`chmod go-rwx`).

`--uninstall` restores the backup byte-for-byte (mode included) when a file is unchanged since the
installer wrote it; otherwise it removes only the Nawala entries/blocks and keeps your later edits.
Directories it created are removed when empty, and the last uninstall removes `~/.nawala`.

## What is sent, and where

Only to the URL you passed with `--url` (stored in `~/.nawala/config`). Nothing goes anywhere else.

The installer makes one call: `GET <url>/api/auth/me` with your token, to check it before any
file is written. `--dry-run` makes no network call.

### Which repos are tracked

Work repos only. Before doing anything for an event, the hook checks the repo's git remote
(`origin`, else the first remote) against the prefixes the server lists for you: your
organisation's client rules and the repos of the projects you are a member of. Personal and
internal repos are never sent: no event, no rules request, not even the remote name.

- `GET <url>/v1/tracking` (2 s timeout) returns the prefixes. It carries no repo information. The
  answer is cached in `~/.nawala/tracking.json` (0600) and refreshed after 15 minutes.
- The match runs on this machine: the remote is normalised (`git@GitLab.com:Org/Repo.git` ->
  `gitlab.com/org/repo`, same rules as the server) and matches a prefix when it equals it or
  starts with it followed by `/`.
- Not tracked: no git remote; `git config nawala.off true` in the repo (per-repo opt-out); a
  remote that matches no prefix.
- If the list cannot be fetched, the cached copy is used whatever its age; with no cached copy,
  nothing is sent (fail closed). A server too old to have `/v1/tracking` (404) gets events as
  before.
- `NAWALA_OFF=1` still pauses everything.

For a tracked repo the hooks (agents with hooks only) send, in the background with a 3 s timeout, `POST <url>/v1/events`:

- the agent name, session id, event type (prompt / stop / start / end), timestamps, client version;
- the working directory, git remote URL, branch, HEAD commit and repository root;
- on prompt: the prompt text, **after local secret scrubbing**;
- on stop: the last 64 KB of the agent's transcript file (when the agent provides one), scrubbed;
- on stop: metadata of your new commits on the branch (sha, author email, date, parents, subject
  line, and per changed file its path with added/deleted line counts), scrubbed;
- the agent's raw hook payload minus the prompt (session id, model name, transcript path, the
  agent's last message on stop), scrubbed, with any value under a secret-looking key replaced.

Never sent: the contents of your source files, diffs, environment variables, other files.

On session start the hook calls `GET <url>/v1/rules?remote=<git remote>&sessionId=...&agent=...`
(2 s timeout) and gives the project's rules to agents that support context injection.

The MCP server (`<url>/mcp`) receives only what the agent passes to the Nawala tools.

**Local scrubbing** (`SCRUB_JQ` in `hook.sh`) mirrors the server's `src/ingest/scrub.ts`: private
keys, Anthropic/OpenAI/GitHub/GitLab/AWS/Slack/Google/Stripe/Nawala keys, JWTs, `Bearer|Basic|Token`
values, passwords in URLs, `PASSWORD=`/`api_key:`-style assignments, and long high-entropy
strings. Over-redaction is accepted. The server scrubs again on arrival. Audit it yourself:

```sh
echo '{"session_id":"s","cwd":"/tmp","prompt":"export DB_PASSWORD=hunter2!!"}' \
  | ~/.nawala/hook.sh prompt --agent claude --print-event      # prints the event, sends nothing
```

The token never appears on a command line (curl reads the header from a 0600 temp file), in the
installer's output (masked as `nwl_****`), or in the dry run.

## Kill switch

- `export NAWALA_OFF=1`: every hook exits immediately and sends nothing (set it in your shell
  profile to stop all tracking; the MCP server stays available).
- Pause from inside the agent: the Nawala MCP tool `pause_tracking`.
- One repo only: `git config nawala.off true` inside it (the hook then makes no network call for it).
- Revoke the token in the Nawala web app: all hooks and MCP calls stop working at once.
- Remove everything: `install.sh --uninstall`.

## How to verify before installing

Download the assets of the release you want (replace the version):

```sh
VERSION=v0.1.0
base="https://github.com/skyshi-labs/nawala-agent-setup/releases/download/$VERSION"
for f in install.sh install.sh.sigstore.json SHA256SUMS SHA256SUMS.sigstore.json; do curl -fsSLO "$base/$f"; done
```

1. **Checksums**

   ```sh
   sha256sum -c --ignore-missing SHA256SUMS            # Linux
   shasum -a 256 -c --ignore-missing SHA256SUMS        # macOS
   ```

2. **Signature** (Sigstore keyless: the signing certificate is bound to this repo's release
   workflow run, and the signature is in the public Rekor transparency log):

   ```sh
   cosign verify-blob --bundle install.sh.sigstore.json --certificate-identity-regexp 'https://github.com/skyshi-labs/nawala-agent-setup/.github/workflows/release.yml@.*' --certificate-oidc-issuer https://token.actions.githubusercontent.com install.sh
   ```

   Stricter (anchored, tags only):

   ```sh
   cosign verify-blob --bundle install.sh.sigstore.json \
     --certificate-identity-regexp '^https://github\.com/skyshi-labs/nawala-agent-setup/\.github/workflows/release\.yml@refs/tags/v[0-9.]+$' \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com install.sh
   ```

   The same works for `hook.sh`, `templates.tar.gz` and `SHA256SUMS` with their `.sigstore.json`.

3. **Compare with the source.** The release `install.sh` is the repo's `install.sh` with `hook.sh`
   and `templates/` pasted in as plain-text heredocs. Rebuild it from the tag and compare:

   ```sh
   git clone https://github.com/skyshi-labs/nawala-agent-setup && cd nawala-agent-setup
   git checkout "$VERSION" && scripts/build-release.sh /tmp/rebuild && cmp /tmp/rebuild/install.sh ../install.sh
   bash ../install.sh --print-file hook.sh | diff - hook.sh      # what would be installed as ~/.nawala/hook.sh
   ```

4. **Run the scanners yourself.** CI runs them on every change and the release attaches their
   reports (`scanner-reports.tar.gz`). To reproduce, put the files an agent receives in one folder:

   ```sh
   mkdir -p scan/nawala-setup && cp skill/nawala-setup/SKILL.md install.sh hook.sh PROMPTS.md scan/nawala-setup/ && cp -R templates scan/nawala-setup/
   pip install cisco-ai-skill-scanner && skill-scanner scan-all scan --recursive --lenient --format markdown   # Cisco AI Defense
   uv tool install git+https://github.com/NVIDIA/skillspector.git && skillspector scan scan/nawala-setup --no-llm   # NVIDIA SkillSpector (Python 3.12+)
   SNYK_TOKEN=... uvx snyk-agent-scan@latest scan/nawala-setup/SKILL.md   # Snyk Agent Scan (needs a free Snyk account)
   shellcheck install.sh hook.sh                                            # ShellCheck
   ```

   Both skill scanners also have an LLM mode (`skill-scanner --use-llm`, SkillSpector without
   `--no-llm` plus a provider key) for a deeper review; CI uses the static analyzers only.

5. **Read the dry run.** `bash install.sh --agent <agent> --url <url> --dry-run` prints a unified
   diff for every file it would create or modify (token masked) and every network call, and
   changes nothing. Add `--full-diff` to include the full `hook.sh`.

### Expected scanner findings

The scanners are built for agent skills, and this repo's job is to edit agent configuration, so
some findings are inherent. Current results on the release contents:

| Scanner | Result | Why |
|---|---|---|
| Semgrep `r/bash` + `p/secrets` | 0 findings (blocking in CI) | |
| ShellCheck | clean (blocking in CI) | |
| Cisco skill-scanner 2.3.2 (static) | 0 findings | |
| NVIDIA SkillSpector 2.13.5 (`--no-llm`) | score 100, "do not install" | **Agent Config Directory Access** (AS1): writing `~/.claude`, `~/.codex`, `~/.gemini`... is the installer's purpose; it is shown in the dry run and reversible. **AS2** (agent settings written): the same MCP/hook entries, listed above. **Chaining Abuse** (TM2): `jq`/`curl`/`git` pipelines in `hook.sh`. **External Transmission** (E1): the documented POST to your Nawala URL. **Session Persistence** (RA2): hooks run in every agent session by design; `NAWALA_OFF=1` and `--uninstall` stop them. **Sudo/Root Execution** (PE2): matches the lines that *refuse* root. **Autonomous Decision Making** (EA2): the OpenCode prompt warns that OpenCode runs shell without asking. **AE1**: the static parser could not fully resolve `install.sh`; read it instead. |

If a scanner reports something not in this table, please open an issue (or a private report if it
looks exploitable).

## Reporting a vulnerability

Please report privately through GitHub: **Security > Report a vulnerability** on
https://github.com/skyshi-labs/nawala-agent-setup/security/advisories/new. Include the version,
the agent, and steps to reproduce. Do not open a public issue for security problems. We aim to
acknowledge within 3 working days and to ship a fixed, signed release for confirmed issues.
