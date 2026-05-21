#Requires -Modules GroupPolicy
<#
.SYNOPSIS
    Exports on-prem GPO and Intune Edge policies to CSV files.
.DESCRIPTION
    Reads all GPOs for Edge-related settings and optionally pulls Intune
    Edge configuration profiles via Microsoft Graph, writing results to
    a local output folder.
.PARAMETER OutputPath
    Folder where CSV files will be written. Created if it does not exist.
.PARAMETER TenantId
    Azure AD tenant ID (required for Intune export).
.PARAMETER ClientId
    App registration client ID (required for Intune export).
.PARAMETER ClientSecret
    App registration client secret (required for Intune export).
.EXAMPLE
    # GPO only
    .\Export-EdgePolicies.ps1 -OutputPath C:\EdgePolicyExport

    # GPO + Intune
    .\Export-EdgePolicies.ps1 -OutputPath C:\EdgePolicyExport `
        -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-secret"
#>
param(
    [string]$OutputPath = "C:\EdgePolicyExport",
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

# ── On-prem GPO Export ────────────────────────────────────────────────────────

Write-Host "Exporting on-prem GPO Edge policies..."

$gpoResults = [System.Collections.Generic.List[PSCustomObject]]::new()

Get-GPO -All | ForEach-Object {
    $gpo = $_
    try {
        [xml]$report = Get-GPOReport -Guid $gpo.Id -ReportType Xml

        # Edge policies live under Software\Policies\Microsoft\Edge
        $report.SelectNodes("//*[contains(@name,'Edge') or contains(@class,'Edge')]") | ForEach-Object {
            $gpoResults.Add([PSCustomObject]@{
                GPOName     = $gpo.DisplayName
                PolicyName  = $_.name
                PolicyValue = $_.value
                State       = $gpo.GpoStatus
                Modified    = $gpo.ModificationTime
            })
        }

        # Also capture any policy under the Edge registry path
        $report.SelectNodes("//q2:RegistrySettings/q2:Registry[contains(q2:Properties/@key,'Microsoft\Edge')]",
            (New-Object System.Xml.XmlNamespaceManager($report.NameTable) |
                ForEach-Object { $_.AddNamespace("q2","http://www.microsoft.com/GroupPolicy/Settings/Registry"); $_ })
        ) | ForEach-Object {
            $props = $_.Properties
            $gpoResults.Add([PSCustomObject]@{
                GPOName     = $gpo.DisplayName
                PolicyName  = $props.valueName
                PolicyValue = $props.value
                State       = $gpo.GpoStatus
                Modified    = $gpo.ModificationTime
            })
        }
    } catch {
        Write-Warning "Could not process GPO '$($gpo.DisplayName)': $_"
    }
}

$gpoCsv = Join-Path $OutputPath "GPO_EdgePolicies.csv"
$gpoResults | Export-Csv -Path $gpoCsv -NoTypeInformation
Write-Host "  GPO export: $($gpoResults.Count) settings -> $gpoCsv"

# ── Intune Export (optional) ──────────────────────────────────────────────────

if ($TenantId -and $ClientId -and $ClientSecret) {
    Write-Host "Exporting Intune Edge policies via Graph API..."

    # Get access token
    $tokenBody = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $ClientId
        client_secret = $ClientSecret
    }
    $token = (Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $tokenBody).access_token

    $headers = @{ Authorization = "Bearer $token" }

    # Get all group policy configurations
    $configs = Invoke-RestMethod -Headers $headers `
        -Uri "https://graph.microsoft.com/v1.0/deviceManagement/groupPolicyConfigurations"

    $intuneResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($config in $configs.value) {
        $definitions = Invoke-RestMethod -Headers $headers `
            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/groupPolicyConfigurations/$($config.id)/definitionValues?`$expand=definition"

        foreach ($def in $definitions.value) {
            # Filter to Edge policies only
            if ($def.definition.categoryPath -notmatch "Edge") { continue }

            $intuneResults.Add([PSCustomObject]@{
                ProfileName    = $config.displayName
                PolicyName     = $def.definition.displayName
                CategoryPath   = $def.definition.categoryPath
                Enabled        = $def.enabled
                LastModified   = $config.lastModifiedDateTime
            })
        }
    }

    $intuneCsv = Join-Path $OutputPath "Intune_EdgePolicies.csv"
    $intuneResults | Export-Csv -Path $intuneCsv -NoTypeInformation
    Write-Host "  Intune export: $($intuneResults.Count) settings -> $intuneCsv"
} else {
    Write-Host "  Skipping Intune export (no credentials provided)."
}

Write-Host "Done. Output folder: $OutputPath"
