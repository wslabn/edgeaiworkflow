<#
.SYNOPSIS
    Compares exported Edge policies against upcoming releases for Stable, Beta,
    and Extended Stable channels, posting a separate Teams alert per channel.
.PARAMETER ExportPath
    Folder containing the CSV exports from Export-EdgePolicies.ps1.
.PARAMETER WebhookUrl
    Teams incoming webhook URL.
.PARAMETER DaysAhead
    How many days ahead to look for upcoming releases. Default: 35.
.EXAMPLE
    .\Send-EdgePolicyAlert.ps1 `
        -ExportPath C:\EdgeMonitor\Export `
        -WebhookUrl "https://your-org.webhook.office.com/..." `
        -DaysAhead 35
#>
param(
    [string]$ExportPath = "C:\EdgePolicyExport",
    [Parameter(Mandatory)]
    [string]$WebhookUrl,
    [int]$DaysAhead = 35
)

$ErrorActionPreference = "Stop"

# ── Known deprecated/changed policies per major version ──────────────────────
# Key = minimum major version where the change takes effect.
$knownChanges = @{
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

# ── Load exported policies once ───────────────────────────────────────────────
$gpoCsv    = Join-Path $ExportPath "GPO_EdgePolicies.csv"
$intuneCsv = Join-Path $ExportPath "Intune_EdgePolicies.csv"

$allPolicies = @()
if (Test-Path $gpoCsv)    { $allPolicies += Import-Csv $gpoCsv    | Select-Object @{n="Source";e={"GPO"}},    @{n="PolicyName";e={$_.PolicyName}} }
if (Test-Path $intuneCsv) { $allPolicies += Import-Csv $intuneCsv | Select-Object @{n="Source";e={"Intune"}}, @{n="PolicyName";e={$_.PolicyName}} }

if ($allPolicies.Count -eq 0) {
    Write-Warning "No policy exports found in $ExportPath. Run Export-EdgePolicies.ps1 first."
    exit 1
}

# ── Fetch Edge release schedule ───────────────────────────────────────────────
Write-Host "Fetching Edge release schedule..."
$releases = Invoke-RestMethod -Uri "https://edgeupdates.microsoft.com/api/products"

# Channels to monitor: API product name -> display label
$channels = [ordered]@{
    "Stable"         = "Stable"
    "Beta"           = "Beta"
    "ExtendedStable" = "Extended Stable"
}

$now      = Get-Date
$cutoff   = $now.AddDays($DaysAhead)

foreach ($apiName in $channels.Keys) {
    $label      = $channels[$apiName]
    $channelData = $releases | Where-Object { $_.Product -eq $apiName }

    if (-not $channelData) {
        Write-Host "[$label] No data returned from API. Skipping."
        continue
    }

    $upcoming = $channelData.Releases |
        Where-Object { $_.PublishedTime -gt $now -and $_.PublishedTime -le $cutoff } |
        Sort-Object PublishedTime |
        Select-Object -First 1

    if (-not $upcoming) {
        Write-Host "[$label] No release found within the next $DaysAhead days. Skipping."
        continue
    }

    $releaseVersion = $upcoming.ProductVersion
    $releaseDate    = ([datetime]$upcoming.PublishedTime).ToString("yyyy-MM-dd")
    $daysUntil      = ([datetime]$upcoming.PublishedTime - $now).Days

    Write-Host "[$label] Upcoming: Edge $releaseVersion on $releaseDate ($daysUntil days away)"

    # Collect applicable policy changes up to this version
    $incomingMajor = [int]($releaseVersion.Split(".")[0])
    $applicableChanges = @{}
    foreach ($ver in $knownChanges.Keys | Where-Object { $_ -le $incomingMajor }) {
        foreach ($key in $knownChanges[$ver].Keys) {
            $applicableChanges[$key] = $knownChanges[$ver][$key]
        }
    }

    $conflicts = $allPolicies |
        Where-Object { $applicableChanges.ContainsKey($_.PolicyName) } |
        Select-Object Source, PolicyName, @{n="Issue"; e={ $applicableChanges[$_.PolicyName] }}

    if ($conflicts.Count -eq 0) {
        Write-Host "[$label] No policy conflicts found. No alert sent."
        continue
    }

    # ── Post Teams alert ──────────────────────────────────────────────────────
    $conflictText = ($conflicts | ForEach-Object { "• [$($_.Source)] **$($_.PolicyName)** — $($_.Issue)" }) -join "`n"

    $card = @{
        type        = "message"
        attachments = @(@{
            contentType = "application/vnd.microsoft.card.adaptive"
            content     = @{
                "`$schema" = "http://adaptivecards.io/schemas/adaptive-card.json"
                type       = "AdaptiveCard"
                version    = "1.4"
                body       = @(
                    @{ type = "TextBlock"; size = "Large"; weight = "Bolder"; text = "⚠️ Edge Policy Conflict — $label Channel" }
                    @{ type = "TextBlock"; text = "Edge **$releaseVersion** ($label) releases in **$daysUntil days** ($releaseDate)"; wrap = $true }
                    @{ type = "TextBlock"; text = "**Affected policies in your config:**"; wrap = $true; weight = "Bolder" }
                    @{ type = "TextBlock"; text = $conflictText; wrap = $true }
                    @{ type = "TextBlock"; text = "Review your GPO and Intune configurations before the release date."; wrap = $true; isSubtle = $true }
                )
            }
        })
    } | ConvertTo-Json -Depth 10

    Invoke-RestMethod -Method Post -Uri $WebhookUrl -Body $card -ContentType "application/json" | Out-Null
    Write-Host "[$label] Teams alert posted. $($conflicts.Count) conflict(s) reported."
}
