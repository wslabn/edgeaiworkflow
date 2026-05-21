# Edge Policy Monitor — Solution Overview

Automated solution that compares your Microsoft Edge group policy settings against the Edge release schedule and posts a Teams alert when upcoming releases may cause conflicts. Uses AI Builder (via Power Automate) to reason about conflicts — no hardcoded rules.

---

## Architecture

The solution is split into two parts because Power Automate cannot reach on-prem Active Directory directly.

### Part 1 — Intune Policies (Power Automate, fully automated)

```
Power Automate Recurrence (every 4 weeks)
    ├─ HTTP GET Edge release API        → upcoming version + release date
    ├─ HTTP GET Edge release notes page → changelog text
    ├─ Graph API                        → Intune Edge policy configurations
    ├─ AI Builder: Create text with GPT → conflict analysis (no hardcoded rules)
    └─ Condition: conflicts found?
            Yes → Post Adaptive Card to Teams channel
            No  → Silent, no alert
```

### Part 2 — On-Prem GPO Policies (PowerShell, runs on a domain-joined server)

```
Task Scheduler (every 4 weeks, aligned to Edge release schedule)
    └─► Export-EdgePolicies.ps1
            ├─ Reads all GPOs via Get-GPOReport
            ├─ Filters for Edge-related registry paths
            └─► Send-EdgePolicyAlert.ps1
                    ├─ HTTP GET Edge release API + release notes
                    ├─ Calls AI Builder via Power Automate HTTP trigger
                    │   (passes GPO policy list + release notes for analysis)
                    └─ Posts Adaptive Card to same Teams channel
```

---

## ⚠️ Limitations

### 1. On-prem GPO data cannot flow directly into Power Automate
Power Automate has no native connector to on-prem Active Directory. The GPO export script must run on a domain-joined server and either push data to Power Automate via an HTTP trigger or post its own Teams alert independently. There is no single unified pipeline for both Intune and GPO data without additional infrastructure.

### 2. No shared storage available
Without a SharePoint site, shared mailbox, or group OneDrive, there is no neutral location for the GPO export file that Power Automate can read automatically. Options to resolve this in the future:
- Use a personal OneDrive as a temporary bridge (not ideal for a shared solution)
- Provision a SharePoint document library
- Deploy an on-prem data gateway (requires Power Automate Premium license)

### 3. On-prem data gateway not available
Connecting Power Automate directly to on-prem resources (AD, file shares) requires an on-prem data gateway installed on a server plus a **Power Automate Premium per-user license**. This is not currently available.

### 4. AI Builder requires credits
The "Create text with GPT" action in AI Builder consumes AI Builder credits. Verify your M365 license includes AI Builder capacity before building the flow. If credits run out, the analysis step will fail silently unless error handling is added to the flow.

### 5. Edge release notes are web-scraped
The flow fetches release notes from the Microsoft Edge docs page via HTTP. If Microsoft changes the URL or page structure, the flow will need to be updated.

### 6. Intune only covers cloud-managed devices
The Power Automate flow reads Intune policies only. Devices managed purely by on-prem GPO are not covered by Part 1 — they are only covered by the PowerShell script in Part 2.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Windows Server with RSAT | For `GroupPolicy` PowerShell module (Part 2 only) |
| Domain-joined machine | Required to read on-prem GPOs (Part 2 only) |
| PowerShell 5.1+ | Built into Windows Server 2016+ |
| Azure AD App Registration | `DeviceManagementConfiguration.Read.All` for Intune via Graph API |
| Teams Incoming Webhook URL | Created in the target Teams channel |
| Power Automate (per-user or included in M365) | For Part 1 flow |
| AI Builder credits | For the GPT analysis step in Power Automate |

---

## Files

| File | Purpose |
|---|---|
| `Export-EdgePolicies.ps1` | Exports on-prem GPO Edge policies to CSV |
| `Send-EdgePolicyAlert.ps1` | Fetches release notes, calls AI Builder, posts Teams alert |
| `EdgePolicyMonitor.md` | This document |

---

## Setup

### Teams Incoming Webhook

1. In Teams, go to the target channel → **...** → **Connectors**
2. Add **Incoming Webhook**, name it `Edge Policy Monitor`
3. Copy the webhook URL — used in both the PowerShell script and the Power Automate flow

### Azure AD App Registration (for Intune + Graph API)

1. **Entra ID** → **App registrations** → **New registration**
2. Name it `EdgePolicyReader`, click **Register**
3. **API permissions** → Add `DeviceManagementConfiguration.Read.All` (Application) → Grant admin consent
4. **Certificates & secrets** → New client secret → copy the value
5. Note the **Application (client) ID** and **Directory (tenant) ID**

### Power Automate Flow (Part 1 — Intune)

1. Create a new **Scheduled cloud flow** — recurrence every 28 days
2. Add **HTTP** action → GET `https://edgeupdates.microsoft.com/api/products`
3. Add **HTTP** action → GET `https://learn.microsoft.com/en-us/deployedge/microsoft-edge-relnote-stable-channel`
4. Add **HTTP** action → GET Intune Edge policies via Graph API (use the app registration credentials)
5. Add **AI Builder: Create text with GPT** — pass release notes + policy list, ask for conflict analysis
6. Add **Condition** — if AI response is not empty/no conflicts, post Adaptive Card to Teams webhook
7. Otherwise end the flow silently

### Task Scheduler (Part 2 — On-prem GPO)

Create two tasks on a domain-joined server, aligned to the same 28-day schedule:

**Task 1 — Export**
- Action: `powershell.exe -NonInteractive -File "C:\EdgeMonitor\Export-EdgePolicies.ps1"`

**Task 2 — Alert (5 minutes after Task 1)**
- Action: `powershell.exe -NonInteractive -File "C:\EdgeMonitor\Send-EdgePolicyAlert.ps1"`

Both tasks must run as a service account with domain read rights.

---

## Script Usage

### Export-EdgePolicies.ps1

```powershell
.\Export-EdgePolicies.ps1 -OutputPath C:\EdgeMonitor\Export
```

### Send-EdgePolicyAlert.ps1

```powershell
.\Send-EdgePolicyAlert.ps1 `
    -ExportPath   C:\EdgeMonitor\Export `
    -WebhookUrl   "https://your-org.webhook.office.com/..." `
    -DaysAhead    30
```

---

## Teams Alert Example

> **⚠️ Edge Policy Conflict Detected**
> Edge **136.0.3240.50** releases in **12 days** (2026-06-02)
>
> **AI Analysis:**
> The policy `LegacySameSiteCookieBehaviorEnabled` is deprecated in this release and will no longer be honored. Your current configuration relies on this policy to allow legacy cookie behavior — this may cause authentication failures on internal sites that depend on cross-site cookies.
>
> Review your GPO and Intune configurations before the release date.

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `Get-GPO` not found | Install RSAT: `Add-WindowsFeature GPMC` |
| Intune export returns 0 results | Verify app registration permissions and admin consent |
| Teams webhook returns 400 | Check webhook URL is still active in Teams channel settings |
| AI Builder step fails | Check AI Builder credit balance in Power Platform admin center |
| No upcoming release found | Edge may be between release cycles — no alert is expected |
