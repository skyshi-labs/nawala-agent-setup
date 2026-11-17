---
inclusion: always
---
<!-- nawala:start -->
## Nawala progress tracking

This machine reports coding-agent work to Nawala (__NAWALA_URL__) through the `nawala` MCP server.
Nawala never receives the conversation: it only knows the intent you report, so for every task:

1. At the start, call the `nawala` MCP tool `set_current_story` with a short `title` that states
   the intent in your own words (or the `story_id` the user gave you). Also pass `remote` = output
   of `git remote get-url origin`, and `model` / `effort` = your own model id and reasoning/effort
   level, if you know them.
2. At the end, call `report_progress` (a step is done) or `complete_story` (the task is done) with
   a one-line `note` of what was done.

Never put secrets, tokens, passwords, file contents or the user's raw prompt in a title or note.
If a tool says this repo is not tracked, stop calling Nawala tools here for this session.
If the `nawala` tools are unavailable or fail, continue the task normally and do not retry.
<!-- nawala:end -->
