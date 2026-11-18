// Nawala plugin for OpenCode 2.x - managed by nawala-agent-setup (remove with install.sh --uninstall).
//
// OpenCode has no shell hooks; this plugin forwards session activity to ~/.nawala/hook.sh, the same
// script the Claude Code / Codex / Cursor hooks run, which decides what (if anything) is sent.
// Passed to hook.sh on stdin: session id, folder, model id, a message/turn id, and for file edits the
// edited file's path. Never the prompt text, the reply, tool output or file contents.
//
//   first prompt of a session (or session.created)  -> hook.sh start
//   session prompt hook                             -> hook.sh prompt
//   session.execution.succeeded/failed/interrupted  -> hook.sh stop
//   session.deleted                                 -> hook.sh end
//   edit tools (write/edit/apply_patch) completed   -> hook.sh touch  (multi-repo workspaces)
//
// Event and hook names verified against OpenCode 2.3.0. Every call is fire-and-forget: a failure
// never throws into OpenCode and never delays a turn.
import { spawn } from "node:child_process"
import { isAbsolute, resolve } from "node:path"

const HOOK = __NAWALA_HOOK_JSON__
// Windows: the Git Bash bash.exe install.sh ran under ("" elsewhere: hook.sh runs directly)
const BASH = __NAWALA_BASH_JSON__
const EDIT_TOOLS = new Set(["write", "edit", "multiedit", "apply_patch", "patch"])
const STOP_EVENTS = ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"]
const TIMEOUT_MS = 15000

// hook.sh reads its config from NAWALA_DIR (the folder hook.sh lives in), so a HOME that differs between
// OpenCode and Git Bash cannot point it at another config
const NAWALA_DIR = HOOK.slice(0, HOOK.lastIndexOf("/"))

function runHook(mode, payload) {
  return new Promise((done) => {
    try {
      const args = [mode, "--agent", "opencode"]
      const env = { ...process.env, NAWALA_DIR }
      // Windows: a login shell (-l) runs Git Bash's /etc/profile, which puts /usr/bin (sed, date, ...) and the
      // user's PATH (jq, git) in place; CHERE_INVOKING=1 keeps it from changing directory
      const child = BASH
        ? spawn(BASH, ["-l", HOOK, ...args], { stdio: ["pipe", "ignore", "ignore"], windowsHide: true, env: { ...env, CHERE_INVOKING: "1" } })
        : spawn(HOOK, args, { stdio: ["pipe", "ignore", "ignore"], env })
      const timer = setTimeout(() => { try { child.kill() } catch {} }, TIMEOUT_MS)
      child.on("error", () => { clearTimeout(timer); done() })
      child.on("close", () => { clearTimeout(timer); done() })
      child.stdin.on("error", () => {})
      child.stdin.end(JSON.stringify(payload))
    } catch {
      done()
    }
  })
}

// Paths an edit tool touched: write/edit carry one path, apply_patch lists them in the patch text.
function editedPaths(input) {
  if (!input || typeof input !== "object") return []
  const out = []
  for (const k of ["filePath", "file_path", "path"]) if (typeof input[k] === "string") out.push(input[k])
  for (const k of ["patchText", "patch_text", "patch", "input"]) {
    if (typeof input[k] !== "string") continue
    for (const m of input[k].matchAll(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/gm)) out.push(m[1].trim())
  }
  return [...new Set(out)].slice(0, 10)
}

export default {
  id: "nawala",
  async setup(ctx) {
    const directory = (ctx.location && ctx.location.directory) || process.cwd()
    const started = new Set()
    const models = new Map()
    let queue = Promise.resolve()
    // one hook run at a time, in event order (start before prompt before stop)
    const send = (mode, sessionID, extra = {}) => {
      if (!sessionID) return
      const payload = { ...extra, sessionID, directory: extra.directory || directory, model: models.get(sessionID) || "" }
      queue = queue.then(() => runHook(mode, payload))
    }
    const ensureStarted = (sessionID, dir) => {
      if (!sessionID || started.has(sessionID)) return
      started.add(sessionID)
      send("start", sessionID, { directory: dir })
    }

    try {
      await ctx.session.hook("context", (e) => {
        if (e && e.sessionID && e.model && e.model.id) {
          models.set(e.sessionID, e.model.providerID ? `${e.model.providerID}/${e.model.id}` : e.model.id)
        }
      })
    } catch {}

    try {
      await ctx.session.hook("prompt", (e) => {
        if (!e || !e.sessionID) return
        ensureStarted(e.sessionID)
        send("prompt", e.sessionID, { prompt_id: e.messageID || "" })
      })
    } catch {}

    try {
      await ctx.tool.hook("execute.after", (e) => {
        if (!e || !e.sessionID || !EDIT_TOOLS.has(e.tool) || e.status === "error") return
        for (const p of editedPaths(e.input)) {
          send("touch", e.sessionID, { tool_input: { file_path: isAbsolute(p) ? p : resolve(directory, p) } })
        }
      })
    } catch {}

    const controller = new AbortController()
    ;(async () => {
      try {
        const types = ["session.created", "session.deleted", ...STOP_EVENTS]
        for await (const e of ctx.event.subscribe({ types, signal: controller.signal })) {
          const sid = e && e.data && e.data.sessionID
          const dir = (e && e.location && e.location.directory) || undefined
          if (!sid) continue
          if (e.type === "session.created") ensureStarted(sid, dir)
          else if (e.type === "session.deleted") {
            started.delete(sid)
            send("end", sid, { directory: dir })
            models.delete(sid)
          } else if (STOP_EVENTS.includes(e.type)) send("stop", sid, { directory: dir, turn_id: e.id || "" })
        }
      } catch {}
    })()
    return () => controller.abort()
  },
}
