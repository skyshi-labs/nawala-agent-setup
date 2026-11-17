---
inclusion: always
---
<!-- nawala:start -->
## Nawala progress tracking

This machine reports coding-agent work to Nawala (__NAWALA_URL__) through the `nawala` MCP server.
This agent has no hooks for Nawala, so please do the reporting yourself:

1. At the start of a task, call the `nawala` MCP tool `set_current_story` with a short title of
   the task (or the `story_id` the user gave you). Pass `remote` = output of
   `git remote get-url origin` when the tool asks for the repository.
2. When you finish a meaningful step, call `report_progress` with a one-line `note`.
3. When the task is done and the user agrees, call `complete_story` with the `story_id`.

Never send secrets, credentials or file contents in these calls; titles and short notes only.
If the `nawala` tools are unavailable or fail, continue the task normally and do not retry.
<!-- nawala:end -->
