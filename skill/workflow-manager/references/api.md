# 使驾 Local API

Base URL: `http://127.0.0.1:5169`. Do not send Authorization. Responses use `{"ok":true,"data":{}}`; errors use `{"ok":false,"error":{"code":"validation_error","message":"..."}}`.

## Multiple Codex sessions per project

One project can bind multiple Codex sessions that share the same working directory. Use the optional `codexSessions` array; each row contains `sessionId`, `codexModel`, and `description`. The first row is the primary session. When `codexSessions` is supplied, it takes precedence over the legacy single-session fields. The project list response includes both `codexSessions` and the legacy `codexSessionId` and `codexModel` fields.

## Resolution

Call `GET /api/projects` first. Compare normalized directories case-insensitively. For current-directory work, query sessions with `workingDirectory`. For history organization, omit it and use `limit`; group by normalized `working_directory`, reuse existing projects, and use only returned session IDs.

## Endpoints

- `GET /api/health`
- `GET /api/projects`
- `GET /api/codex/sessions?workingDirectory=<path>&limit=100`
- `POST /api/projects`
- `PATCH /api/projects/{projectId}`
- `POST /api/projects/{projectId}/workflows`
- `GET /api/projects/{projectId}/workflows/{workflowId}`
- `PUT /api/projects/{projectId}/workflows/{workflowId}`
- `DELETE /api/projects/{projectId}/workflows/{workflowId}`

Project create body:

```json
{"name":"PowerUI","defaultWorkingDirectory":"D:\\workspace\\PowerUI","codexSessionId":"<returned-session-id>","codexModel":"gpt-5.4"}
```

Project patch accepts `name`, `defaultWorkingDirectory`, `codexSessionId`, and `codexModel`. `codexModel` is optional; leave it empty to use the Codex default model. A project may also be created with an empty `codexSessionId`; the 使驾 project conversation page creates and binds a new session after the first message.

Workflow creation accepts `{"name":"Build and test"}` or `{"workflow":<complete workflow>}`. Replacement requires a complete workflow with `Name`, `Nodes`, and `Edges`; read it before replacing it.

## Workflow Schema

Core fields: `Name`, `Enabled`, `ScheduleMode`, `ScheduleKind`, `ScheduleTime`, `ScheduleWeekdays`, `ScheduleDayOfMonth`, `IntervalMinutes`, `NextRunUtc`, `Nodes`, and `Edges`.

Node fields: `Id`, `Type`, `Name`, `X`, `Y`, `Width`, `Height`, `Config`. Edge fields: `From`, `To`, `Branch`. Branches are `True`/`False` for `If` and `Body`/`Done` for `ForEach`.

Node types: `Start`, `End`, `HttpRequest`, `EnvRead`, `EnvWrite`, `Variable`, `Cmd`, `Python`, `Codex`, `If`, `ForEach`, `LoopEnd`, `Delay`, and `Balloon`.

Python node configuration:

```json
{
  "Mode": "Inline",
  "Script": "print('hello from 使驾')",
  "WorkingDirectory": "",
  "Arguments": "",
  "TimeoutSeconds": "",
  "OutputVar": "pythonResult",
  "FailOnError": true
}
```

`Mode` is `Inline` or `File`. For `File`, `Script` is the `.py` path and may be relative to the project working directory. An empty `WorkingDirectory` inherits the project directory. The interpreter comes from the optional global Python interpreter setting, or falls back to `python.exe` from `PATH`. An empty `TimeoutSeconds` waits until completion and remains stoppable from running tasks. The output variable exposes `ExitCode`, `StdOut`, `StdErr`, `ProcessId`, `InterpreterPath`, `WorkingDirectory`, `Mode`, and `ScriptPath`.
