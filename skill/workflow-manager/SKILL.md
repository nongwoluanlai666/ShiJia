---
name: workflow-manager
description: Manage local 使驾 projects, Codex session associations, and visual workflows through its localhost HTTP API. Use when Codex needs to inspect or organize historical sessions into 使驾 projects, match the current directory to a project, or create, read, edit, and delete project workflows.
---

# 使驾

Use the local API at `http://127.0.0.1:5169`. Do not send an authorization header. The service is bound to localhost only.

使驾 is a lightweight PowerShell/WinForms workflow editor and scheduler. Projects group related workflows, define a default working directory, optionally force a Codex model, and associate a Codex session. A project without a session ID can create and bind one from its first conversation message. Workflows contain visual nodes such as CMD, Python, HTTP request, variables, conditions, loops, delays, notifications, and Codex calls. Python nodes can run inline code or a `.py` file, stream stdout/stderr into the running-task page, publish a result variable, and inherit the project's working directory plus the optional global Python interpreter.

## 使驾项目与多会话

使驾支持一个项目绑定多个 Codex 会话并共享同一默认工作目录。项目列表中的 `codexSessions` 每项包含 `sessionId`、`codexModel` 和 `description`，第一项是主会话；旧字段 `codexSessionId` 和 `codexModel` 仍保留用于兼容。切换会话时只切换当前对话页面，不停止其它项目会话的后台执行。

## Required Flow

1. Call `projects` before every project or workflow management task.
2. Normalize directory paths, remove trailing separators, and compare them case-insensitively with `defaultWorkingDirectory`.
3. Reuse a matching project unless the user explicitly asks for another project.
4. For the current directory, call `sessions` with that working directory when no project matches. Select a real returned `session_id`; never invent one.
5. For requests that organize recent history, call `sessions` without `-WorkingDirectory` and set the requested `-Limit`. Group results by normalized, non-empty `working_directory`, prefer the newest relevant session per directory, skip missing directories, and reuse existing projects.
6. Create projects with the session's real `working_directory` and `session_id`. Derive a concise project name from the directory or session title and avoid duplicate normalized directories.
7. Perform workflow operations only with the chosen `projectId`. Read an existing workflow before replacing it.
8. Use `PUT` with the complete workflow document for edits. Preserve graph structure and keep at least one `Start` and one `End` node.
9. Do not edit 使驾 JSON files or Codex session JSONL files directly. Use session summaries only; do not mutate unrelated Codex history.

If 使驾 is not reachable, ask the user to start its packaged executable.

## Client

Use the bundled PowerShell client in `scripts/invoke-workflow-manager.ps1`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/invoke-workflow-manager.ps1 projects
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/invoke-workflow-manager.ps1 sessions -WorkingDirectory $PWD.Path
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/invoke-workflow-manager.ps1 sessions -Limit 10
```

For fields, workflow schema, responses, and examples, read [references/api.md](references/api.md).

