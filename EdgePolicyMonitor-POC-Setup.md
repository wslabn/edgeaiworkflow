# Edge Policy Monitor — Personal Azure POC Setup Guide

A proof-of-concept that automatically compares your Edge browser policies against the Microsoft Edge release schedule and posts a Teams alert when conflicts are detected. Runs entirely in Azure — no servers, no on-prem dependencies.

---

## How It Works

```
Azure Logic App (runs every 4 weeks)
    │
    ├─ 1. Fetch Edge release schedule from Microsoft's public API
    ├─ 2. Fetch Edge release notes from Microsoft Docs
    ├─ 3. Read your Edge policy config from Azure Blob Storage
    ├─ 4. Send all three to Azure OpenAI (GPT-4o) for conflict analysis
    └─ 5. If conflicts found → post alert to Microsoft Teams channel
         If no conflicts   → silent, nothing happens
```

The AI reads the actual release notes and your actual policy list and reasons about them — no hardcoded rules, no lookup tables. As Microsoft changes Edge, the analysis adapts automatically.

---

## What You Need

| Resource | Purpose |
|---|---|
| Azure subscription | Hosts everything |
| Azure OpenAI resource | GPT-4o model for conflict analysis |
| Azure Blob Storage account | Stores your Edge policy config file |
| Azure Logic App | Orchestrates the workflow on a schedule |
| Microsoft Teams channel | Receives the alert |

---

## Step 1 — Deploy a GPT-4o Model in Azure OpenAI

1. Open **portal.azure.com**
2. Navigate to your **Azure OpenAI** resource
3. Click **Model deployments** → **Deploy model**
4. Select **gpt-4o** (or **gpt-4o-mini** for lower cost)
5. Set a deployment name — e.g., `gpt-4o`
6. Click **Deploy**

**Save these values — you will need them later:**
- Endpoint URL (found under **Keys and Endpoint**)
- API Key (found under **Keys and Endpoint**)
- Deployment name (what you typed in step 5)

---

## Step 2 — Set Up Blob Storage

1. Open your **Storage Account** in the portal
2. Click **Containers** → **+ Container**
3. Name it `edge-policy-monitor`, leave access level as **Private**
4. Click **Create**
5. Open the new container and click **Upload**
6. Upload a CSV file named `edge-policies.csv` with your Edge policy settings

**Sample `edge-policies.csv` format:**

```csv
Source,PolicyName,Value
GPO,SitePerProcess,Enabled
GPO,SSLVersionMin,tls1
GPO,LegacySameSiteCookieBehaviorEnabled,1
Intune,InternetExplorerIntegrationLevel,1
Intune,DefaultPluginsSetting,2
```

Add or remove rows to match your actual policies. When policies change, upload a new version of this file — the next Logic App run will pick it up automatically.

**Save these values:**
- Storage account name
- Container name (`edge-policy-monitor`)
- Storage account connection string (found under **Access keys**)

---

## Step 3 — Create a Teams Incoming Webhook

1. Open **Microsoft Teams**
2. Go to the channel where you want alerts posted
3. Click **...** next to the channel name → **Manage channel** (or **Connectors**)
4. Find **Incoming Webhook** → click **Add** → **Add** again
5. Give it a name: `Edge Policy Monitor`
6. Click **Create** and copy the webhook URL

**Save this value:**
- Webhook URL

---

## Step 4 — Create the Logic App

1. In the portal, click **Create a resource** → search **Logic App**
2. Select **Logic App** (Consumption plan — pay per use, cheapest option)
3. Fill in:
   - **Resource group**: use an existing one or create new
   - **Logic App name**: `edge-policy-monitor`
   - **Region**: same region as your storage account
4. Click **Review + create** → **Create**
5. Once deployed, click **Go to resource**
6. Click **Logic app designer** → **Add a trigger** → search **Recurrence**
7. Set recurrence to **every 28 days** (Edge Stable releases every ~4 weeks)

**Build the flow with these actions in order:**

### Action 1 — Get Edge Release Schedule
- Add action: **HTTP**
- Method: `GET`
- URI: `https://edgeupdates.microsoft.com/api/products`

### Action 2 — Get Edge Release Notes
- Add action: **HTTP**
- Method: `GET`
- URI: `https://learn.microsoft.com/en-us/deployedge/microsoft-edge-relnote-stable-channel`

### Action 3 — Read Policy Config from Blob
- Add action: **Azure Blob Storage — Get blob content**
- Connect to your storage account using the connection string from Step 2
- Container: `edge-policy-monitor`
- Blob: `edge-policies.csv`

### Action 4 — Analyze with Azure OpenAI
- Add action: **HTTP**
- Method: `POST`
- URI: `https://<your-openai-endpoint>/openai/deployments/<your-deployment-name>/chat/completions?api-version=2024-02-01`
- Headers:
  - `api-key`: your Azure OpenAI API key
  - `Content-Type`: `application/json`
- Body:
```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are an IT administrator analyzing Microsoft Edge policy compatibility. Be concise and specific."
    },
    {
      "role": "user",
      "content": "Here are the upcoming Edge release notes:\n\n@{body('Get_Edge_Release_Notes')}\n\nHere are our currently configured Edge policies:\n\n@{body('Get_blob_content')}\n\nIdentify any policies in our config that are deprecated, removed, or have changed behavior in this release. If there are no conflicts, respond with exactly: NO CONFLICTS FOUND"
    }
  ],
  "max_tokens": 800
}
```

### Action 5 — Check for Conflicts
- Add action: **Condition**
- Check: does the AI response body **not contain** `NO CONFLICTS FOUND`

**If Yes (conflicts found):**
- Add action: **HTTP**
- Method: `POST`
- URI: your Teams webhook URL
- Body:
```json
{
  "type": "message",
  "attachments": [
    {
      "contentType": "application/vnd.microsoft.card.adaptive",
      "content": {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": [
          {
            "type": "TextBlock",
            "size": "Large",
            "weight": "Bolder",
            "text": "⚠️ Edge Policy Conflict Detected"
          },
          {
            "type": "TextBlock",
            "text": "@{body('Analyze_with_OpenAI')?['choices'][0]['message']['content']}",
            "wrap": true
          }
        ]
      }
    }
  ]
}
```

**If No (no conflicts):** leave empty — the flow ends silently.

---

## Estimated Cost

| Service | Estimated monthly cost |
|---|---|
| Logic App (Consumption) | < $0.05 (runs once every 4 weeks) |
| Azure OpenAI (gpt-4o-mini) | < $0.01 per run |
| Blob Storage | < $0.01 |
| **Total** | **~$0.10/month or less** |

---

## Updating Your Policy Config

When policies are added or removed:

1. Edit your local `edge-policies.csv`
2. Go to portal → Storage Account → `edge-policy-monitor` container
3. Upload the new file (overwrite the existing one)

The next scheduled run will automatically use the updated file. No changes to the Logic App needed.

---

## Troubleshooting

| Issue | Fix |
|---|---|
| Logic App run fails on HTTP action | Check the Edge API URL is still valid |
| OpenAI action returns 401 | Verify API key is correct and not expired |
| Blob read fails | Check connection string and container/blob name match exactly |
| Teams webhook returns 400 | Recreate the webhook in Teams — they can expire |
| AI always says no conflicts | Check the blob content is being passed correctly in the prompt |

---

## Next Steps (Beyond POC)

- **Replace the CSV** with a live Graph API call to read real Intune policies automatically
- **Add a Logic App HTTP trigger** so the PowerShell GPO export script can push on-prem policy data into the same flow
- **Move secrets** (API key, webhook URL) to **Azure Key Vault** instead of hardcoding in the Logic App
