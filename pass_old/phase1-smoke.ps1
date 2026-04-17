param(
    [string]$BaseUrl = "http://inference.local",
    [string]$ApiKey = "ollama-poc-key",
    [string]$Model = "llama3.2",
    [string]$OutFile = "pass/phase1-inference-probe-report.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-TestCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$BodyJson,
        [Parameter(Mandatory = $true)][int[]]$ExpectedStatus
    )

    $uri = "$BaseUrl$Path"
    $startedAt = Get-Date
    $isPwsh7OrNewer = $PSVersionTable.PSVersion.Major -ge 7
    try {
        if ($isPwsh7OrNewer) {
            $resp = Invoke-WebRequest `
                -Uri $uri `
                -Method $Method `
                -Headers $Headers `
                -Body $BodyJson `
                -ContentType "application/json" `
                -TimeoutSec 30 `
                -SkipHttpErrorCheck
            $statusCode = [int]$resp.StatusCode
            $body = [string]$resp.Content
        } else {
            $resp = Invoke-WebRequest `
                -Uri $uri `
                -Method $Method `
                -Headers $Headers `
                -Body $BodyJson `
                -ContentType "application/json" `
                -TimeoutSec 30
            $statusCode = [int]$resp.StatusCode
            $body = [string]$resp.Content
        }
    } catch {
        $statusCode = -1
        $body = $_.Exception.Message
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                    $reader.Close()
                }
            } catch {
                # Keep original error message when body cannot be read.
            }
        }
    }

    $ok = $ExpectedStatus -contains $statusCode
    [pscustomobject]@{
        name = $Name
        method = $Method
        path = $Path
        expected = $ExpectedStatus
        actual = $statusCode
        pass = $ok
        started_at = $startedAt.ToString("o")
        body_preview = if ($body.Length -gt 280) { $body.Substring(0, 280) } else { $body }
    }
}

$headers = @{
    "api-key" = $ApiKey
}

$chatBody = @{
    model = $Model
    messages = @(
        @{
            role = "user"
            content = "Say OK only."
        }
    )
    stream = $false
} | ConvertTo-Json -Depth 6

$responsesBody = @{
    model = $Model
    input = "hello"
} | ConvertTo-Json -Depth 4

$results = @()

# Case 1: Phase 1 allowed path (should be 200 when route is healthy)
$results += Invoke-TestCase `
    -Name "allowed_chat_completions" `
    -Path "/v1/chat/completions" `
    -Method "POST" `
    -Headers $headers `
    -BodyJson $chatBody `
    -ExpectedStatus @(200)

# Case 2: Phase 1 denied path in chat-only mode (should be 403)
$results += Invoke-TestCase `
    -Name "denied_responses_endpoint" `
    -Path "/v1/responses" `
    -Method "POST" `
    -Headers $headers `
    -BodyJson $responsesBody `
    -ExpectedStatus @(403)

$summary = [pscustomobject]@{
    base_url = $BaseUrl
    model = $Model
    total = @($results).Count
    passed = @($results | Where-Object { $_.pass }).Count
    failed = @($results | Where-Object { -not $_.pass }).Count
    generated_at = (Get-Date).ToString("o")
    results = $results
}

$dir = Split-Path -Path $OutFile -Parent
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir | Out-Null
}
$summary | ConvertTo-Json -Depth 8 | Out-File -FilePath $OutFile -Encoding utf8

Write-Host ""
Write-Host "Phase 1 inference probe result:"
Write-Host ("- Base URL: {0}" -f $BaseUrl)
Write-Host ("- Passed: {0}/{1}" -f $summary.passed, $summary.total)
Write-Host ("- Report: {0}" -f $OutFile)

if ($summary.failed -gt 0) {
    Write-Host ""
    Write-Host "Failed cases:"
    $results | Where-Object { -not $_.pass } | ForEach-Object {
        Write-Host ("- {0}: expected [{1}], actual {2}" -f $_.name, ($_.expected -join ","), $_.actual)
    }
    exit 1
}

