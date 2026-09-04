param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('health','projects','sessions','create-project','update-project','create-workflow','get-workflow','update-workflow','delete-workflow')]
    [string]$Action,
    [string]$ProjectId,
    [string]$WorkflowId,
    [string]$Name,
    [string]$WorkingDirectory,
    [string]$SessionId,
    [string]$Json,
    [string]$JsonFile,
    [int]$Limit = 100,
    [string]$BaseUrl = 'http://127.0.0.1:5169'
)

$ErrorActionPreference = 'Stop'

function Get-RequestBody {
    if (-not [string]::IsNullOrWhiteSpace($JsonFile)) {
        return [IO.File]::ReadAllText((Resolve-Path -LiteralPath $JsonFile), [Text.Encoding]::UTF8)
    }
    return $Json
}

function Invoke-WorkflowManagerRequest {
    param([string]$Method, [string]$Path, [string]$Body = '')
    $parameters = @{ Uri = ($BaseUrl.TrimEnd('/') + $Path); Method = $Method; UseBasicParsing = $true; TimeoutSec = 30 }
    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes($Body)
    }
    try {
        $response = Invoke-WebRequest @parameters
        return ([string]$response.Content | ConvertFrom-Json)
    } catch {
        if ($null -ne $_.Exception.Response) {
            $stream = $_.Exception.Response.GetResponseStream()
            try {
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
                try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $stream.Dispose() }
            if (-not [string]::IsNullOrWhiteSpace($content)) { throw $content }
        }
        throw
    }
}

switch ($Action) {
    'health' { $result = Invoke-WorkflowManagerRequest GET '/api/health' }
    'projects' { $result = Invoke-WorkflowManagerRequest GET '/api/projects' }
    'sessions' {
        $query = '?limit=' + [Math]::Min(500, [Math]::Max(1, $Limit))
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $query += '&workingDirectory=' + [Uri]::EscapeDataString($WorkingDirectory) }
        $result = Invoke-WorkflowManagerRequest GET ('/api/codex/sessions' + $query)
    }
    'create-project' {
        if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($WorkingDirectory)) { throw 'create-project requires -Name and -WorkingDirectory.' }
        $body = [pscustomobject]@{ name=$Name; defaultWorkingDirectory=$WorkingDirectory; codexSessionId=$SessionId } | ConvertTo-Json -Compress
        $result = Invoke-WorkflowManagerRequest POST '/api/projects' $body
    }
    'update-project' {
        if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw 'update-project requires -ProjectId.' }
        $raw = Get-RequestBody
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $body = $raw }
        else {
            $properties = [ordered]@{}
            if (-not [string]::IsNullOrWhiteSpace($Name)) { $properties.name = $Name }
            if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $properties.defaultWorkingDirectory = $WorkingDirectory }
            if ($PSBoundParameters.ContainsKey('SessionId')) { $properties.codexSessionId = $SessionId }
            $body = [pscustomobject]$properties | ConvertTo-Json -Compress
        }
        $result = Invoke-WorkflowManagerRequest PATCH ('/api/projects/' + [Uri]::EscapeDataString($ProjectId)) $body
    }
    'create-workflow' {
        if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw 'create-workflow requires -ProjectId.' }
        $raw = Get-RequestBody
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $body = [pscustomobject]@{ workflow=($raw | ConvertFrom-Json) } | ConvertTo-Json -Depth 40 -Compress }
        else { $body = [pscustomobject]@{ name=$(if ([string]::IsNullOrWhiteSpace($Name)) { 'New workflow' } else { $Name }) } | ConvertTo-Json -Compress }
        $result = Invoke-WorkflowManagerRequest POST ('/api/projects/' + [Uri]::EscapeDataString($ProjectId) + '/workflows') $body
    }
    'get-workflow' {
        if ([string]::IsNullOrWhiteSpace($ProjectId) -or [string]::IsNullOrWhiteSpace($WorkflowId)) { throw 'get-workflow requires -ProjectId and -WorkflowId.' }
        $result = Invoke-WorkflowManagerRequest GET ('/api/projects/' + [Uri]::EscapeDataString($ProjectId) + '/workflows/' + [Uri]::EscapeDataString($WorkflowId))
    }
    'update-workflow' {
        if ([string]::IsNullOrWhiteSpace($ProjectId) -or [string]::IsNullOrWhiteSpace($WorkflowId)) { throw 'update-workflow requires -ProjectId and -WorkflowId.' }
        $raw = Get-RequestBody
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'update-workflow requires -Json or -JsonFile with a complete workflow.' }
        $body = [pscustomobject]@{ workflow=($raw | ConvertFrom-Json) } | ConvertTo-Json -Depth 40 -Compress
        $result = Invoke-WorkflowManagerRequest PUT ('/api/projects/' + [Uri]::EscapeDataString($ProjectId) + '/workflows/' + [Uri]::EscapeDataString($WorkflowId)) $body
    }
    'delete-workflow' {
        if ([string]::IsNullOrWhiteSpace($ProjectId) -or [string]::IsNullOrWhiteSpace($WorkflowId)) { throw 'delete-workflow requires -ProjectId and -WorkflowId.' }
        $result = Invoke-WorkflowManagerRequest DELETE ('/api/projects/' + [Uri]::EscapeDataString($ProjectId) + '/workflows/' + [Uri]::EscapeDataString($WorkflowId))
    }
}

$result | ConvertTo-Json -Depth 40
