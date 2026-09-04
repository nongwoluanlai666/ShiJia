param(
    [string]$Output = (Join-Path $PSScriptRoot 'WorkflowManager.exe')
)

$ErrorActionPreference = 'Stop'
$ps2exe = Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue
if ($null -eq $ps2exe) { $ps2exe = Get-Command ps2exe -ErrorAction SilentlyContinue }
if ($null -eq $ps2exe) { throw '未找到 PS2EXE。先执行：Install-Module ps2exe -Scope CurrentUser' }

$source = Join-Path $PSScriptRoot 'WorkflowManager.ps1'
$restartScript = Join-Path $PSScriptRoot 'restartShiJia.py'
if (-not (Test-Path -LiteralPath $restartScript)) { throw 未找到重启脚本：$restartScript }
$skillRoot = Join-Path $PSScriptRoot 'skill\workflow-manager'
$iconFile = Join-Path $PSScriptRoot 'assets\workflow-manager.ico'
$iconGenerator = Join-Path $PSScriptRoot 'generate-icon.ps1'
& $iconGenerator -Output $iconFile | Out-Null
$requestedOutput = [IO.Path]::GetFullPath($Output)
$outputDirectory = Split-Path -Parent $requestedOutput
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
$runningTarget = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { -not [string]::IsNullOrWhiteSpace($_.Path) -and [string]::Equals([IO.Path]::GetFullPath($_.Path), $requestedOutput, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
})
$compileOutput = $requestedOutput
if ($runningTarget.Count -gt 0) {
    $compileOutput = Join-Path $outputDirectory (([IO.Path]::GetFileNameWithoutExtension($requestedOutput)) + '.next' + [IO.Path]::GetExtension($requestedOutput))
    if (Test-Path -LiteralPath $compileOutput) { Remove-Item -LiteralPath $compileOutput -Force }
    Write-Host "目标程序正在运行（PID：$((@($runningTarget.Id) -join ', '))），本次生成待应用版本：$compileOutput"
}
$embeddedFiles = @{
    '.\workflow-ai\skills\workflow-manager\SKILL.md' = (Join-Path $skillRoot 'SKILL.md')
    '.\workflow-ai\skills\workflow-manager\agents\openai.yaml' = (Join-Path $skillRoot 'agents\openai.yaml')
    '.\workflow-ai\skills\workflow-manager\scripts\invoke-workflow-manager.ps1' = (Join-Path $skillRoot 'scripts\invoke-workflow-manager.ps1')
    '.\workflow-ai\skills\workflow-manager\references\api.md' = (Join-Path $skillRoot 'references\api.md')
    '.\web\index.html' = (Join-Path $PSScriptRoot 'web\index.html')
}
$buildStartedAt = Get-Date
$fallbackSkillRoot = Join-Path $outputDirectory 'skill\workflow-manager'
$fallbackWebRoot = Join-Path $outputDirectory 'web'
& $ps2exe -InputFile $source -OutputFile $compileOutput -NoConsole -STA -IconFile $iconFile -EmbedFiles $embeddedFiles -Title '使驾' -Description '轻量本地与 Web 工作流管理执行工具' -Company '使驾' -Product '使驾' -Version '1.24.2.0'
if (-not (Test-Path -LiteralPath $compileOutput)) { throw "PS2EXE 未生成输出文件：$compileOutput" }
$builtItem = Get-Item -LiteralPath $compileOutput
if ($builtItem.LastWriteTime -lt $buildStartedAt.AddSeconds(-2)) { throw "PS2EXE 输出文件时间未更新，构建可能失败：$compileOutput" }
if (Test-Path -LiteralPath $fallbackSkillRoot) { Remove-Item -LiteralPath $fallbackSkillRoot -Recurse -Force }
New-Item -ItemType Directory -Path $fallbackSkillRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Destination (Join-Path $fallbackSkillRoot 'SKILL.md') -Force
$fallbackAgentsRoot = Join-Path $fallbackSkillRoot 'agents'
$fallbackScriptsRoot = Join-Path $fallbackSkillRoot 'scripts'
$fallbackReferencesRoot = Join-Path $fallbackSkillRoot 'references'
New-Item -ItemType Directory -Path $fallbackAgentsRoot,$fallbackScriptsRoot,$fallbackReferencesRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $skillRoot 'agents\openai.yaml') -Destination (Join-Path $fallbackAgentsRoot 'openai.yaml') -Force
Copy-Item -LiteralPath (Join-Path $skillRoot 'scripts\invoke-workflow-manager.ps1') -Destination (Join-Path $fallbackScriptsRoot 'invoke-workflow-manager.ps1') -Force
Copy-Item -LiteralPath (Join-Path $skillRoot 'references\api.md') -Destination (Join-Path $fallbackReferencesRoot 'api.md') -Force
if ($compileOutput -eq $requestedOutput) {
    if (-not (Test-Path -LiteralPath $fallbackWebRoot)) { New-Item -ItemType Directory -Path $fallbackWebRoot -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'web\index.html') -Destination (Join-Path $fallbackWebRoot 'index.html') -Force
} else {
    Write-Host '当前正式实例仍在运行，已保留其 Web 页面文件；新版启动时会释放与后端匹配的内嵌页面。'
}
Copy-Item -LiteralPath $restartScript -Destination (Join-Path $outputDirectory 'restartShiJia.py') -Force
if ($compileOutput -ne $requestedOutput) {
    Write-Host "已生成待应用版本：$compileOutput"
    Write-Host '在使驾中右键执行“重启使驾”，旧实例退出后会自动替换并启动新版。'
} else {
    Write-Host "已生成：$requestedOutput"
}
