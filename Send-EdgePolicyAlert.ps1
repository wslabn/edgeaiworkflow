<#
.SYNOPSIS
    Compares exported Edge policies against the upcoming Edge release and posts a Teams alert.
.PARAMETER ExportPath
    Folder containing the CSV exports from Export-EdgePolicies.ps1.
.PARAMETER WebhookUrl
    Teams incoming webhook URL.
.PARAMETER DaysAhead
    How many days ahead to look for upcoming Edge releases. Default: 30.
.EXAMPLE
    .\Send-EdgePolicyAlert.ps1 `
        -ExportPath C:\EdgeMonitor\Export `
        -WebhookUrl "https://your-org.webhook.office.com/..." `
        -DaysAhead 30
#>
param(
    [string]$ExportPath  = "C:\EdgePolicyExport",
    [Parameter(Mandatory)]
    [string]$WebhookUrl,
    [int]$DaysAhead = 30
)

$ErrorActionPreference = "Stop"

# ── Fetch Edge release schedule ───────────────────────────────────────────────

Write-Host "Fetching Edge release schedule..."
$releases = Invoke-RestMethod -Uri "https://edgeupdates.microsoft.com/api/products"

$stableChannel = $releases | Where-Object { $_.Product -eq "Stable" }
$upcoming = $stableChannel.Releases |
    Where-Object { $_.PublishedTime -gt (Get-Date) -and
                   $_.PublishedTime -le (Get-Date).AddDays($DaysAhead) } |
    Sort-Object PublishedTime |
    Select-Object -First 1

if (-not $upcoming) {
    Write-Host "No Edge Stable release found within the next $DaysAhead days. No alert sent."
    exit 0
}

$releaseVersion = $upcoming.ProductVersion
$releaseDate    = ([datetime]$upcoming.PublishedTime).ToString("yyyy-MM-dd")
$daysUntil      = ([datetime]$upcoming.PublishedTime - (Get-Date)).Days

Write-Host "Upcoming release: Edge $releaseVersion on $releaseDate ($daysUntil days away)"

# ── Load exported policies ────────────────────────────────────────────────────

$gpoCsv    = Join-Path $ExportPath "GPO_EdgePolicies.csv"
$intuneCsv = Join-Path $ExportPath "Intune_EdgePolicies.csv"

$allPolicies = @()
if (Test-Path $gpoCsv)    { $allPolicies += Import-Csv $gpoCsv    | Select-Object @{n="Source";e={"GPO"}},    @{n="PolicyName";e={$_.PolicyName}} }
if (Test-Path $intuneCsv) { $allPolicies += Import-Csv $intuneCsv | Select-Object @{n="Source";e={"Intune"}}, @{n="PolicyName";e={$_.PolicyName}} }

if ($allPolicies.Count -eq 0) {
    Write-Warning "No policy exports found in $ExportPath. Run Export-EdgePolicies.ps1 first."
    exit 1
}

# ── Known deprecated/changed policies per major version ──────────────────────
# Extend this hashtable as new Edge versions are released.
# Key = minimum major version where the change takes effect.

$knownChanges = @{
    # Format: MajorVersion = @{ PolicyName = "Description of change" }
    120 = @{
        "LegacySameSiteCookieBehaviorEnabled" = "Deprecated — SameSite cookie enforcement is now mandatory"
        "SSLVersionMin"                        = "Default changed to TLS 1.2; TLS 1.0/1.1 no longer supported"
    }
    124 = @{
        "DefaultPluginsSetting"               = "Plugin support removed; policy has no effect"
        "EnableDeprecatedWebPlatformFeatures" = "Deprecated — legacy web platform features removed"
    }
    130 = @{
        "InternetExplorerIntegrationLevel"    = "IE mode deprecation warning added; plan migration"
    }
    136 = @{
        "LegacySSLVersionMax"                 = "Removed — SSL 3.0 and TLS 1.0 no longer configurable"
        "SitePerProcess"                      = "Now enforced by default; policy to disable it is removed"
    }
}

$incomingMajor = [int]($releaseVersion.Split(".")[0])

# Collect all changes that apply up to and including the incoming version
$applicableChanges = @{}
foreach ($ver in $knownChanges.Keys | Where-Object { $_ -le $incomingMajor }) {
    foreach ($key in $knownChanges[$ver].Keys) {
        $applicableChanges[$key] = $knownChanges[$ver][$key]
    }
}

# Find conflicts: policies in your config that appear in the applicable changes list
$conflicts = $allPolicies | Where-Object { $applicableChanges.ContainsKey($_.PolicyName) } |
    Select-Object Source, PolicyName, @{n="Issue"; e={ $applicableChanges[$_.PolicyName] }}

# ── Zip the export folder ─────────────────────────────────────────────────────

$zipPath = Join-Path (Split-Path $ExportPath -Parent) "EdgePolicyExport_$(Get-Date -Format 'yyyyMMdd').zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path $ExportPath -DestinationPath $zipPath
Write-Host "Zipped export: $zipPath"

# ── Post Teams alert ──────────────────────────────────────────────────────────

if ($conflicts.Count -eq 0) {
    Write-Host "No policy conflicts found. No Teams alert sent."
    exit 0
}

$conflictLines = $conflicts | ForEach-Object { "• [$($_.Source)] **$($_.PolicyName)** — $($_.Issue)" }
$conflictText  = $conflictLines -join "`n"

$card = @{
    type        = "message"
    attachments = @(@{
        contentType = "application/vnd.microsoft.card.adaptive"
        content     = @{
            "`$schema" = "http://adaptivecards.io/schemas/adaptive-card.json"
            type       = "AdaptiveCard"
            version    = "1.4"
            body       = @(
                @{ type = "TextBlock"; size = "Large"; weight = "Bolder"; text = "⚠️ Edge Policy Conflict Detected" }
                @{ type = "TextBlock"; text = "Edge **$releaseVersion** releases in **$daysUntil days** ($releaseDate)"; wrap = $true }
                @{ type = "TextBlock"; text = "**Affected policies in your config:**"; wrap = $true; weight = "Bolder" }
                @{ type = "TextBlock"; text = $conflictText; wrap = $true }
                @{ type = "TextBlock"; text = "Review your GPO and Intune configurations before the release date."; wrap = $true; isSubtle = $true }
            )
        }
    })
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Post -Uri $WebhookUrl -Body $card -ContentType "application/json" | Out-Null
Write-Host "Teams alert posted. $($conflicts.Count) conflict(s) reported."
