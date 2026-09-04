# 使驾

使驾是一款轻量级本地工作流管理和执行工具，使用 Windows PowerShell + WinForms 编写，可通过 PS2EXE 打包为 exe。
<img width="1920" height="1032" alt="image" src="https://github.com/user-attachments/assets/a0092a4c-66e7-4aba-9c1f-83933e1aaaf0" />
<img width="922" height="847" alt="image" src="https://github.com/user-attachments/assets/3ac9d09a-0741-44b8-91a5-a980b2dd2955" />
<img width="1903" height="905" alt="image" src="https://github.com/user-attachments/assets/0e6b8a21-de04-473a-b0a7-a70dfecf56c2" />
<img width="652" height="787" alt="image" src="https://github.com/user-attachments/assets/6965eddc-ab88-4ff3-8aec-1d578cfa6f5a" />

## 功能

- 项目分组：项目包含名称、默认工作目录和 Codex 会话 ID；旧工作流自动归入“无项目”。选择项目后只展示该项目的工作流，新建任务自动归属当前项目。
- 项目工具：支持打开项目目录、用 VS Code 打开，以及在主页面恢复关联的 Codex 历史会话或启动真实 Codex 终端会话；项目会话按项目隔离。
- 会话管理：顶部入口集中展示项目会话的“对话进行中 / 工作流调用中 / 已完成 / 未创建”状态、Session ID、模型、目录和更新时间，按会话或项目更新时间倒序排列，双击会按选中的会话描述跳转，包括尚未创建 Session ID 的辅助会话。
- 全局配置：Codex、VS Code 和会话代码/文档打开器等设备相关路径集中保存在本机 `settings.json`，可手工填写或浏览选择，不再重复写入工作流节点。
- 本地 HTTP API：应用常驻时监听 `http://127.0.0.1:5169`，无需 Authorization，可列出/创建/编辑项目，列出 Codex 会话摘要，并在项目下创建、读取、替换和删除工作流。服务仅绑定本机回环地址，并拒绝网页跨源请求。
- 项目会话选择：新建或编辑项目时可浏览最近 Codex 会话，选中后自动带入会话工作目录与 Session ID。
- 多会话项目：同一项目可以绑定多个 Codex 会话，共享项目工作目录；第一行是主会话，项目 Codex 对话入口会在多会话时弹出描述菜单，会话页可通过下拉框快速切换，切换不会停止其它会话的后台执行。
- 使驾 AI：工具栏入口使用独立持久 Codex session 管理项目与工作流，不复用项目或其他历史会话。打开页面会自动加载该 session 的最近对话；Skill 随 EXE 分发到 `workflow-ai\skills\workflow-manager`，专用工作目录为 EXE 旁的 `workflow-ai`。
- 可视化画布：开始、结束、网络请求、CMD、调用 Codex、变量读取/写入、变量赋值、条件判断、遍历循环、循环结束、延时和 Windows 气泡提醒节点。
- 节点拖拽、端口拖拽连线、双击配置节点；右键节点可编辑、复制和删除，右键空白处可粘贴，右键连线可删除。也支持 `Ctrl+C`、`Ctrl+V` 和 `Delete`。
- 工作任务列表支持右键复制和粘贴，也支持 `Ctrl+C`、`Ctrl+V`；副本会归入当前项目、重建节点与连线 ID，并默认关闭定时启用状态。
- 在 Codex 会话或使驾 AI 页面单击、右击工作任务时只更新选中项，不离开会话页面；双击工作任务才切回该任务的配置和画布。
- 工作任务右键菜单支持执行一次、停止、重新执行、上移、下移、复制粘贴和删除。对运行中的任务选择“重新执行”时，会先终止 Worker、CMD、Codex 等子进程，清理完成后再启动一次新执行。
- 画布默认范围为当前显示器宽高的两倍，节点拖到边缘时自动扩展；网格会覆盖整个滚动区域。
- 多个工作任务独立保存，支持循环执行（间隔、每日、每周、每月）和执行一次（间隔、下一个指定时间）。
- 全部工作流配置可导出为 JSON，也可从 JSON 导入并替换当前配置。
- 工作流由独立的隐藏 PowerShell worker 进程后台执行，支持多个任务并行运行，网络请求不会阻塞编辑器。
- 顶部“运行中任务”按钮右侧提供独立的“常用提示词”入口；提示词管理以可缩放的非模态悬浮窗口打开，不遮挡当前会话，支持新增、编辑、删除、双击复制和按钮复制，并随全局配置导入导出。旧配置中意外写入的布尔值或 `False` 文本会自动清理。
- 网络请求节点在同一次任务中复用 `WebRequestSession`，可连续执行登录和后续请求。
- 系统托盘常驻；最小化保持 Windows 标准任务栏最小化，关闭窗口才隐藏到托盘。左键单击托盘图标打开主窗口，右键菜单可运行任务或退出。
- 执行日志显示在界面并写入 `%LOCALAPPDATA%\PowerUI\WorkflowManager\logs`。
- 工作流定义保存在 `%LOCALAPPDATA%\PowerUI\WorkflowManager\workflows.json`。
- 项目定义保存在 `%LOCALAPPDATA%\PowerUI\WorkflowManager\projects.json`，全局设备路径保存在同目录的 `settings.json`。
- 首次运行会安装随机数条件分支、清单循环提醒和系统信息变量流转三个禁用示例，不会自动执行。

## 运行

```powershell
powershell -ExecutionPolicy Bypass -File .\WorkflowManager.ps1
```

工作流中的模板可以引用：

- `{{env.NAME}}`：任务环境变量或当前进程环境变量。
- `{{var.NAME}}`：当前任务中节点写入的变量，也支持 `{{var.login.data}}` 这样的路径。
- `{{date:yyyy-MM-dd}}`：按当前时间格式化。

变量写入节点直接用表格配置“变量名 / 值模板”，写入后同时可以通过 `{{var.NAME}}` 和 CMD 环境变量使用，不需要再连接读取节点。变量读取节点用于把 Windows 或已有任务环境变量按表格映射导入任务变量。写入的值只在当前任务执行期间存在，不会修改 Windows 全局环境变量。

表格支持多行批量配置；旧版单项和 JSON 配置会在加载时自动兼容并可重新保存为表格格式。

CMD 节点通过隐藏的 `cmd.exe` 执行多行命令，可设置工作目录、超时和非零退出码处理。超时留空时表示无限等待，工作流会停留在当前 CMD 节点、持续采集实时输出，并可从“运行中任务”页面手动停止；填写秒数时才会在到时后终止。结果变量包含 `ExitCode`、`StdOut`、`StdErr` 和进程信息，例如 `{{var.cmdResult.StdOut}}`。

调用 Codex 节点使用“全局配置”中的 Codex 路径。节点工作目录和会话 ID 留空时继承所属项目；无项目工作流默认使用 `%TEMP%`。会话 ID 留空时以 `codex.exe -C <工作目录> exec --yolo --skip-git-repo-check <需求及实时数据>` 新建会话；存在会话 ID 时以 `codex.exe exec --yolo --skip-git-repo-check resume <SESSION_ID> <需求及实时数据>` 恢复历史会话。项目的“终端打开”使用交互命令 `codex.exe --yolo -C <项目目录> resume <SESSION_ID>`。默认结果变量 `codexResult` 包含 `ExitCode`、`StdOut`、`StdErr`、`CodexPath`、`WorkingDirectory`、`SessionId` 和 `InvocationMode`。

变量赋值节点支持文本、数字、布尔值和 JSON，可以把 CMD 或网络请求结果解析后继续通过 `{{var.NAME.path}}` 传递。

条件判断节点最多连接两条输出，画布会自动标记为“是”和“否”。遍历循环节点最多连接两条输出，分别标记为“循环”和“完成”；循环分支末尾连接“循环结束”节点，当前项、序号和循环统计都可保存为任务变量。

内置的“动态变量示例：CMD 随机数”展示了完整链路：CMD 节点把结果保存到 `randomResult`，后续气泡节点通过 `{{var.randomResult.StdOut}}` 读取输出。

Windows 气泡提醒可配置点击行为：无动作、打开本地文件或目录、使用默认浏览器打开 `http/https` URL。点击目标支持 `{{var.xxx}}`、`{{env.xxx}}` 和环境变量路径；系统托盘一次只维护最近显示气泡的点击目标。

Codex 会话页使用 WinForms `RichTextBox` 原生能力实现轻量 Markdown 美化，不引入第三方渲染依赖。支持标题、列表、引用、分隔线、粗体、行内代码、代码块、Markdown 链接和裸 URL；顶部 `↑` 按钮每次定位到上一个由用户发送的消息。

会话页右侧文件树支持将路径插入对话、打开文件或目录、定位并选中文件、在 `pwd` 终端中打开，以及在 PowerShell 中打开；右键菜单支持使用系统文件剪贴板复制、粘贴，删除项目时会移入回收站；选择文件执行终端操作时会自动进入其所在目录。

会话中的链接使用 `Ctrl + 左键单击` 操作，避免普通选择文本时误触：`http/https` 由默认浏览器打开；目录由资源管理器打开；`.exe` 只在资源管理器中定位而不执行；代码和文本文件由全局配置的编辑器打开，首次使用可选择 Notepad++、记事本或其它编辑器，Notepad++ 支持 `文件路径:行号` 定位；Word、Excel、PDF 等其它文件交给系统默认程序打开。相对路径会基于当前项目目录解析。

工具图标源文件位于 `assets/workflow-manager.svg`。

## 本地 HTTP API

健康检查：

```powershell
Invoke-RestMethod http://127.0.0.1:5169/api/health
```

主要接口：

- `GET /api/projects`：列出“无项目”、项目详情和工作流摘要。
- `GET /api/codex/sessions?workingDirectory=<路径>&limit=100`：读取 `%USERPROFILE%\.codex\sessions` 的 JSONL 会话摘要，包含 `time`、`title`、`session_id`、`working_directory`。
- `POST /api/projects`：新建项目。
- `PATCH /api/projects/{projectId}`：编辑项目。
- 项目 API 兼容字段：`codexSessions` 是会话数组，每项包含 `sessionId`、`codexModel`、`description`，第一项是主会话；项目列表同时保留 `codexSessionId` 和 `codexModel` 供旧客户端使用。
- `POST /api/projects/{projectId}/workflows`：新建工作流。
- `GET /api/projects/{projectId}/workflows/{workflowId}`：读取完整工作流。
- `PUT /api/projects/{projectId}/workflows/{workflowId}`：用完整工作流 JSON 替换现有工作流。
- `DELETE /api/projects/{projectId}/workflows/{workflowId}`：删除工作流。

对应 Codex Skill 安装在 `%USERPROFILE%\.codex\skills\workflow-manager`，详细字段规范和示例位于 Skill 的 `references/api.md`。

## Web 远程访问

在“全局配置”中勾选启用 Web，并配置访问码与端口；默认端口为 `5170`，默认不启用。启用后监听 `0.0.0.0:<端口>`，适合通过防火墙、FRP 或其它受控入口访问。除登录页和登录接口外，所有 Web 接口都需要登录后取得的 Bearer Token。

移动端页面以 Codex 会话为主页面，侧边菜单支持切换项目、切换会话和新建会话；工作流触发/停止、运行中任务实时日志和会话管理集中在工作流页面。浏览器会按项目保存当前会话选择，后台刷新不会覆盖用户正在使用的下拉选项。

主要 Web 会话接口：

- `POST /web/api/auth/login`：使用 `accessCode` 登录并取得 Token。
- `GET /web/api/bootstrap`：读取项目、会话、工作流和运行任务摘要。
- `POST /web/api/projects/{projectId}/sessions`：新建一条待创建会话，可填写 `description` 和 `model`。
- `GET /web/api/projects/{projectId}/sessions/{sessionKey}/status`：读取会话运行状态。
- `GET /web/api/projects/{projectId}/sessions/{sessionKey}/messages`：读取会话消息。
- `POST /web/api/projects/{projectId}/sessions/{sessionKey}/messages`：异步发送 Codex 消息，请求体为 `{ "message": "..." }`。
- `POST /web/api/projects/{projectId}/sessions/{sessionKey}/stop`：手动停止正在运行的 Codex 会话。

已有会话的 `sessionKey` 就是 Session ID；尚未首次发送的会话使用 `_new-0`、`_new-1` 这样的稳定键。首次回复完成后，使驾会把 Codex 返回的 Session ID 绑定回对应会话行。

## 打包 exe

```powershell
Install-Module ps2exe -Scope CurrentUser
.\build.ps1
```

输出文件默认为 `WorkflowManager.exe`，也可以指定路径：

```powershell
.\build.ps1 -Output .\dist\WorkflowManager.exe
```

## 自检

```powershell
powershell -ExecutionPolicy Bypass -File .\WorkflowManager.ps1 -SelfTest
powershell -ExecutionPolicy Bypass -File .\WorkflowManager.ps1 -UiSmokeTest
powershell -ExecutionPolicy Bypass -File .\WorkflowManager.ps1 -NetworkSelfTest
powershell -ExecutionPolicy Bypass -File .\WorkflowManager.ps1 -TrayPersistenceTest
```

## 关于
开发这个工具的原因是电脑老是被高内存拖累，本人平时使用vscode codex插件，对话呈现和脚本执行等不太便利，玩耍过程中发现ai用powershell给我开发了个图形化工具，于是意识到 powershell winform + py2exe 可以实现超轻便的UI，于是做了这个个自定义壳。过了大概一两周deepseek harness和codex harness出现了，其实大差不差，未来软件使用就应该是私人化自主定制的。


