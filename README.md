# SMS and Voice Retirement

## Overview

This repository deploys an Azure-based data collection pipeline to identify users who still sign in with SMS or voice authentication and to compare that usage with the authentication methods they have already registered in Microsoft Entra ID.

The solution exists to answer a practical retirement question:

- Which users are still actively using SMS or voice as a sign-in method?
- Which of those users already have stronger methods registered, such as passkeys or other passwordless methods?
- Which applications are still associated with recent SMS or voice usage?

The deployment stores Microsoft Graph `userRegistrationDetails` data in a custom Log Analytics table and then correlates that data with sign-in telemetry by using KQL.

## Why this is required

Retiring telephony-based authentication requires more than a policy change. Before disabling SMS or voice, you need evidence that shows:

- who is still using those methods,
- whether safer alternatives are already registered,
- and where the remaining operational impact is likely to be.

Microsoft Graph provides the registration posture, but it does not provide your investigation-ready history inside Log Analytics by default. This repository bridges that gap by:

- querying Microsoft Graph for user registration details,
- normalizing that data into a custom Log Analytics table,
- and making it available for hunting and reporting alongside sign-in logs.

## Architecture

The solution uses four components:

1. A Log Analytics custom table to store user registration posture.
2. A Data Collection Rule (DCR) that defines the ingestion schema and destination table.
3. A Logic App with a system-assigned managed identity that calls Microsoft Graph and posts records to the Logs Ingestion API.
4. A PowerShell script that grants the managed identity the Microsoft Graph application permission it needs.

Flow:

1. The Logic App runs on a schedule.
2. It calls `https://graph.microsoft.com/beta/reports/authenticationMethods/userRegistrationDetails?$top=1000` by using its managed identity.
3. It loops through the returned records.
4. It posts each record to the DCR Logs Ingestion endpoint.
5. Azure Monitor writes the data into `MfaUserRegistration_CL`.
6. You query that table together with sign-in logs to identify SMS and voice dependencies.

## Repository contents

- `mfa-table.json`: creates the custom Log Analytics table `MfaUserRegistration_CL`.
- `dcr-mfa.json`: creates the DCR, the custom stream declaration, and the data flow to the custom table.
- `logicApp-mfa.json`: creates the Logic App, enables a system-assigned managed identity, and assigns `Monitoring Metrics Publisher` on the DCR.
- `permissionsGraph-SP.ps1`: assigns the Microsoft Graph application permission `AuditLog.Read.All` to the Logic App managed identity by resolving the Logic App service principal from its display name.

## Prerequisites

Before deployment, make sure you have:

- an Azure subscription,
- an existing Log Analytics workspace,
- rights to deploy ARM templates in the target resource group,
- rights to assign Azure RBAC roles on the DCR,
- rights to assign Microsoft Graph application permissions to a service principal,
- Azure CLI installed and authenticated,
- Microsoft Graph PowerShell SDK installed for the permission assignment script.

The Log Analytics workspace must already exist. This repository does not create the workspace itself.

## Required permissions

Two permission models are used in this solution.

### Azure RBAC

The Logic App managed identity needs permission to send data to the DCR. The template handles this automatically by assigning:

- `Monitoring Metrics Publisher` on the DCR scope.

### Microsoft Graph application permission

The Logic App managed identity calls Microsoft Graph by using managed identity authentication. To read `userRegistrationDetails`, the managed identity must receive the Graph application permission used by this repository:

- `AuditLog.Read.All`

That permission is not granted by the ARM templates. It is assigned separately by the PowerShell script in this repository.

## Deployment order

The order matters because each step depends on the previous one.

### Step 1: Create the custom table

Deploy `mfa-table.json` first.

```powershell
az deployment group create `
    --resource-group <resource-group> `
    --template-file mfa-table.json `
    --parameters workspaceName=<log-analytics-workspace-name>
```

This creates the `MfaUserRegistration_CL` table in your Log Analytics workspace.

### Step 2: Create the Data Collection Rule

Deploy `dcr-mfa.json` second.

First, retrieve the exact workspace resource ID:

```powershell
$workspaceResourceId = az monitor log-analytics workspace show `
    --resource-group <workspace-resource-group> `
    --workspace-name <log-analytics-workspace-name> `
    --query id -o tsv
```

Then deploy the DCR:

```powershell
az deployment group create `
    --resource-group <resource-group> `
    --template-file .\dcr-mfa.json `
    --parameters workspaceResourceId="$workspaceResourceId" workspaceLocation=<workspace-location>
```

Important:

- `workspaceResourceId` must be the full Azure resource ID, not the workspace GUID.
- `workspaceLocation` must match the Log Analytics workspace region.

Expected format for `workspaceResourceId`:

```text
/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>
```

### Step 3: Create the Logic App

Deploy `logicApp-mfa.json` after the DCR exists.

```powershell
az deployment group create `
    --resource-group <resource-group> `
    --template-file .\logicApp-mfa.json `
    --parameters logicAppName=<logic-app-name> dcrName=dcr-mfa-user-registration
```

This deployment:

- creates the Logic App,
- enables a system-assigned managed identity,
- reads the DCR ingestion endpoint and immutable ID,
- and assigns `Monitoring Metrics Publisher` to the managed identity on the DCR.

### Step 4: Grant Microsoft Graph permission to the managed identity

After the Logic App is created, update the variables in `permissionsGraph-SP.ps1`:

- `$TenantID` with your Entra tenant ID,
- `$DisplayNameMI` with the Logic App name,
- and keep `$GraphPermission` set to `AuditLog.Read.All` unless you intentionally change the API permission model.

The script then:

- connects to Microsoft Graph with the required delegated scopes,
- finds the Logic App service principal by display name,
- resolves the Microsoft Graph service principal,
- and assigns the application role directly to the managed identity.

Run it with:

```powershell
pwsh .\permissionsGraph-SP.ps1
```

The script assigns `AuditLog.Read.All` to the Logic App managed identity against Microsoft Graph.

## How the implementation works

### 1. Custom table

`mfa-table.json` defines the target schema. The columns are aligned with the user registration details returned by Microsoft Graph, plus `TimeGenerated` for Log Analytics ingestion.

### 2. Data Collection Rule

`dcr-mfa.json` defines:

- the custom stream name,
- the schema expected by the ingestion endpoint,
- the Log Analytics destination,
- and the mapping from the incoming custom stream to `MfaUserRegistration_CL`.

### 3. Logic App

`logicApp-mfa.json` implements the scheduled workflow:

- trigger on a daily recurrence by default,
- call Microsoft Graph using managed identity authentication,
- initialize an array from the returned `value` payload,
- loop over the records,
- add `TimeGenerated`,
- and post each item to the Logs Ingestion API.

### 4. Permission assignment script

`permissionsGraph-SP.ps1` uses Microsoft Graph PowerShell to assign the Microsoft Graph app role directly to the Logic App managed identity service principal. It does not require you to manually copy the managed identity object ID into the script.

## Validation after deployment

Use these checks to confirm the deployment is working.

### Validate the DCR

```powershell
az monitor data-collection rule show `
    --resource-group <resource-group> `
    --name dcr-mfa-user-registration
```

### Validate the Logic App managed identity

```powershell
az resource show \
    --resource-group <resource-group> `
    --name <logic-app-name> `
    --resource-type Microsoft.Logic/workflows `
    --query identity
```

### Validate data arrival in Log Analytics

Run a query such as:

```kusto
MfaUserRegistration_CL
| take 10
```

If no data appears, review the Logic App run history and confirm both permissions are in place:

- `Monitoring Metrics Publisher` on the DCR,
- `AuditLog.Read.All` on the managed identity service principal.

Also confirm that `$DisplayNameMI` in the PowerShell script exactly matches the Logic App resource name.

## Hunting query example

After the pipeline is ingesting successfully, use the following query to identify users who recently used SMS or voice and already have stronger methods registered.

```kusto
let Registration =
        MfaUserRegistration_CL
        | extend UPN = tolower(userPrincipalName)
        | extend Methods = todynamic(methodsRegistered)
        | summarize arg_max(TimeGenerated, *) by UPN
        | extend
                HasMobilePhone = Methods has "mobilePhone",
                HasOfficePhone = Methods has "officePhone",
                HasPasskey = Methods has "passKeyDeviceBound" or Methods has "passkeySynced";

SigninLogs
| where TimeGenerated > ago(30d)
| where ResultType == 0
| mv-expand AuthDetail = todynamic(AuthenticationDetails)
| extend
        UPN = tolower(UserPrincipalName),
        UsedMethod = tostring(AuthDetail.authenticationMethod),
        StepSucceeded = tobool(AuthDetail.succeeded)
| where StepSucceeded
| where UsedMethod in ("Text message", "Voice call")
| summarize
        UsageCount = count(),
        LastUsage = max(TimeGenerated),
        Applications = make_set(AppDisplayName, 20)
        by UPN, UsedMethod
| join kind=leftouter Registration on UPN
| where HasPasskey == true
| project
        UPN,
        methodsRegistered = Methods,
        defaultMfaMethod,
        HasMobilePhone,
        HasOfficePhone,
        HasPasskey,
        UsedMethod,
        UsageCount,
        LastUsage,
        Applications
| order by LastUsage desc
```

## Troubleshooting

### `workspaceResourceId` is invalid

This is the most common deployment mistake for `dcr-mfa.json`.

Use the full Azure resource ID, not:

- the workspace customer ID,
- the workspace GUID,
- or a partial resource path.

Retrieve it with Azure CLI instead of typing it manually.

### DCR deployment succeeds but outputs fail

If the DCR is created but the deployment output evaluation fails, verify the API version support in your CLI or deployment tooling and confirm the DCR can be queried directly afterward.

### Logic App cannot call Microsoft Graph

Confirm that:

- the managed identity exists,
- the Graph app role assignment completed successfully,
- and admin consent requirements in your tenant are satisfied.

### Logic App cannot ingest into Log Analytics

Confirm that:

- the DCR exists,
- the Logic App has `Monitoring Metrics Publisher` on the DCR,
- the DCR points to the correct workspace,
- and the stream schema matches the custom table schema.

## References

- Azure Monitor Logs Ingestion API overview: https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview
- Azure Monitor tutorial with ARM templates: https://learn.microsoft.com/azure/azure-monitor/logs/tutorial-logs-ingestion-api
- Azure Monitor prerequisites for Logs Ingestion API: https://learn.microsoft.com/azure/azure-monitor/logs/set-up-logs-ingestion-api-prerequisites