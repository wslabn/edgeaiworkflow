# Edge AI Workflow — Edge Policy Monitor

Automatically detects conflicts between your Microsoft Edge browser policies and upcoming Edge releases, then posts an alert to a Microsoft Teams channel. No manual review required.

---

## The Problem

Microsoft Edge releases a new Stable version roughly every 4 weeks. Each release can deprecate, remove, or change the behavior of group policies. IT teams managing Edge via Group Policy (GPO) or Intune often miss these changes until something breaks in production.

---

## Two Approaches

### Approach 1 — Azure POC (Recommended Starting Point)

> **Best for:** Proving the concept quickly with minimal infrastructure. Runs entirely in Azure with no servers required.

**How it works:**
An Azure Logic App runs every 28 days and:
1. Fetches the upcoming Edge release schedule from Microsoft's public API
2. Fetches the latest Edge release notes from Microsoft Docs
3. Reads your Edge policy list from a CSV file stored in Azure Blob Storage
4. Sends all three to **Azure OpenAI (GPT-4o)** and asks it to identify conflicts
5. If conflicts are found, posts an Adaptive Card alert to a Teams channel

**Key advantage:** The AI reads the actual release notes and reasons about your actual policies — no hardcoded rules. As Microsoft changes Edge, the analysis adapts automatically.

**Estimated cost:** ~$0.10/month

**Files:**
- [`EdgePolicyMonitor-POC-Setup.md`](EdgePolicyMonitor-POC-Setup.md) — full step-by-step setup guide

---

### Approach 2 — Enterprise / On-Prem (Full Coverage)

> **Best for:** Organizations with on-prem Active Directory GPOs that are not covered by Intune or Azure.

**How it works:**
Two PowerShell scripts run on a domain-joined Windows Server via Task Scheduler every 28 days:

1. **`Export-EdgePolicies.ps1`** — reads all GPOs via `Get-GPOReport`, filters for Edge-related registry settings, and optionally pulls Intune Edge policies via Microsoft Graph API. Writes results to CSV files.
2. **`Send-EdgePolicyAlert.ps1`** — fetches the Edge release schedule, compares your exported policies against a known list of deprecated/changed policies per Edge version, and posts an Adaptive Card alert to Teams if conflicts are found.

**Key advantage:** Covers on-prem GPO-managed devices that cloud-only solutions cannot reach.

**Limitation:** Conflict detection uses a maintained lookup table of known policy changes. The table must be updated as new Edge versions introduce breaking changes.

**Files:**
- [`Export-EdgePolicies.ps1`](Export-EdgePolicies.ps1) — GPO + Intune policy export script
- [`Send-EdgePolicyAlert.ps1`](Send-EdgePolicyAlert.ps1) — conflict check and Teams alert script
- [`EdgePolicyMonitor.md`](EdgePolicyMonitor.md) — architecture overview and setup guide

---

## Comparison

| | Azure POC | Enterprise / On-Prem |
|---|---|---|
| Infrastructure | Azure Logic App + Blob Storage | Domain-joined Windows Server |
| Policy sources | CSV file (manual) or Intune via Graph | On-prem GPO + Intune via Graph |
| Conflict detection | AI-driven (GPT-4o, no hardcoded rules) | Rule-based (maintained lookup table) |
| On-prem GPO support | ❌ | ✅ |
| Setup complexity | Low | Medium |
| Estimated cost | ~$0.10/month | Free (server already exists) |

---

## Recommended Path

1. **Start with the Azure POC** to validate the concept and see the Teams alerts in action.
2. **Extend to the enterprise approach** once you need on-prem GPO coverage, or add an HTTP trigger to the Logic App so the PowerShell script can push GPO data into the same AI-driven flow.
