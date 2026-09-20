# Evidence

Live proof for the claims in the [README](../README.md#proof-points) and
[ARCHITECTURE.md](ARCHITECTURE.md). Every block below is real output from this
pipeline's subscription, captured at 2026-09-20T07:28:31Z by
[`scripts/capture-evidence.sh`](../scripts/capture-evidence.sh). The first line of
each block is the command that produced it. The owner email, subscription ID, tenant
ID and my Entra object ID are replaced with placeholders.

| Name used in the commands | Value |
|---|---|
| `STG` (evidence storage account) | `stgrcevid4obhbq` |
| `COSMOS_NAME` (evidence database account) | `cosmos-grc-evidence-4obhbq` |
| `GH_REPO` | `gregorywilsonjr/cgeaz` |
| `REMEDIATION_PID` (`id-grc-remediation-dev`) | `c224b2bb-a300-413e-a666-525f7276beda` |
| `COLLECTOR_PID` (collector Function) | `cacc0d2f-0990-475b-8c42-db353d394079` |
| `REPORTER_PID` (reporter Function) | `4449aee0-c619-42fe-89be-0f37bd221d84` |
| `CI_SP_ID` (GitHub Actions; app ID `6b3f517f-6b6c-4d96-8251-0cea35459fb2`) | `2b05fe4d-c914-4e54-b459-e0a33359bfff` |

## 1. Reports can't be changed or deleted

The `reports` container has a time-based retention (WORM) policy. A new probe blob is
written, then deleting it and overwriting it are both refused, for every identity. The
last block shows the probe still there and never modified.

```text
$ az storage container immutability-policy show --account-name "$STG" --container-name reports --resource-group rg-grc-evidence-dev --query "{retentionDays:immutabilityPeriodSinceCreationInDays, state:state}" -o table
RetentionDays    State
---------------  --------
90               Unlocked
```

```text
$ az storage blob upload --account-name "$STG" --container-name reports --name "$PROBE" --file "$TMP/probe.txt" --auth-mode login -o none && echo "uploaded $PROBE"
Alive[################################################################]  100.0000%Finished[#############################################################]  100.0000%
uploaded evidence/worm-probe-20260920T072832Z.txt
```

```text
$ az storage blob delete --account-name "$STG" --container-name reports --name "$PROBE" --auth-mode login
ERROR: This operation is not permitted as the blob is immutable due to a policy.
RequestId:bd1c32f9-b01e-0048-4fd1-4878a7000000
Time:2026-09-20T07:28:35.9740801Z
ErrorCode:BlobImmutableDueToPolicy
```

```text
$ az storage blob upload --account-name "$STG" --container-name reports --name "$PROBE" --file "$TMP/overwrite.txt" --auth-mode login --overwrite -o none
ERROR: This operation is not permitted as the blob is immutable due to a policy.
RequestId:cdf62d06-401e-004c-06d1-48f5a0000000
Time:2026-09-20T07:28:36.8782047Z
ErrorCode:BlobImmutableDueToPolicy
If you want to overwrite the existing one, please add --overwrite in your command.
```

```text
$ az storage blob show --account-name "$STG" --container-name reports --name "$PROBE" --auth-mode login --query "{name:name, created:properties.creationTime, lastModified:properties.lastModified}" -o table
Name                                      Created                    LastModified
----------------------------------------  -------------------------  -------------------------
evidence/worm-probe-20260920T072832Z.txt  2026-09-20T07:28:35+00:00  2026-09-20T07:28:35+00:00
```

## 2. Every report number traces to a stored query

Each report in the WORM container, re-checked against the evidence store today with its
own collection run:
`SELECT VALUE COUNT(1) FROM c WHERE c.runId = @run AND c.status = 'Unhealthy'`.
The list is also the run history: one POA&M per day and one SAR per week since the
timers went live. The query runs as me, through the data-plane role stage 03 grants me.

| Report | Collection run | Report says | Store query today | Reproduces |
|---|---|---|---|---|
| `poam/2026/09/poam-2026-09-20.json` | `2ef7fe8c-4e43-4cf3-aa72-fa4aa2c0e91b` | 32 | 0 | no |
| `sar/2026/09/sar-2026-09-20.md` | `2ef7fe8c-4e43-4cf3-aa72-fa4aa2c0e91b` | 32 | 0 | no |

0 of 2 reports reproduce from the store today.
A report that doesn't reproduce was built from documents that a later collection run overwrote.

## 3. Collection lineage

The newest collection run, what it wrote, and one of its documents with its run
stamps. Also the document count in each container.

```text
assessments  58 documents
frameworks   7 documents
mappings     0 documents

newest run:   297f9d16-e24c-4dcb-ba2e-3a424e265425
collected at: 2026-09-20T05:00:00.824671+00:00
documents:    58  by status: {'Healthy': 17, 'NotApplicable': 8, 'Unhealthy': 33}
unhealthy by severity: {'High': 4, 'Low': 8, 'Medium': 9, 'Unknown': 12}
```

```json
{
  "id": "544e3e08a54acb3880031264d588ea19",
  "runId": "297f9d16-e24c-4dcb-ba2e-3a424e265425",
  "collectedAt": "2026-09-20T05:00:00.824671+00:00",
  "assessmentId": "cdc78c07-02b0-4af0-1cb2-cb7c672a8b0a",
  "displayName": "Storage account should use a private link connection",
  "status": "Unhealthy",
  "severity": "Medium",
  "resourceId": "/subscriptions/<subscription-id>/resourcegroups/rg-grc-sandbox-dev/providers/microsoft.storage/storageaccounts/stgrcseed17735"
}
```

## 4. The preventive control fires

A live attempt to create a storage account that allows public blob access.
`cge-deny-public-blob` is at Deny, so Azure refuses the request and nothing is created.

```text
$ az policy assignment show --name cge-grc-baseline --scope /providers/Microsoft.Management/managementGroups/mg-grc-sandbox --query "parameters.publicBlobEffect.value" -o tsv
Deny
```

```text
$ az storage account create --name "$DENY_NAME" --resource-group rg-grc-sandbox-dev --location eastus --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access true -o none 2>&1 | head -n 12
ERROR: (RequestDisallowedByPolicy) Resource 'stgrcdeny0920072849' was disallowed by policy. Policy identifiers: '[{"policyAssignment":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyAssignments/cge-grc-baseline"},"policyDefinition":{"name":"Storage accounts must not allow public blob access","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyDefinitions/cge-deny-public-blob","version":"1.0.0"},"policySetDefinition":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policySetDefinitions/cge-grc-baseline","version":"1.0.0"}}]'.
Code: RequestDisallowedByPolicy
Message: Resource 'stgrcdeny0920072849' was disallowed by policy. Policy identifiers: '[{"policyAssignment":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyAssignments/cge-grc-baseline"},"policyDefinition":{"name":"Storage accounts must not allow public blob access","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyDefinitions/cge-deny-public-blob","version":"1.0.0"},"policySetDefinition":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policySetDefinitions/cge-grc-baseline","version":"1.0.0"}}]'.
Target: stgrcdeny0920072849
Additional Information:Type: PolicyViolation
Info: {
    "evaluationDetails": {
        "evaluatedExpressions": [
            {
                "result": "True",
                "expressionKind": "Field",
                "expression": "type",
```

## 5. The gate blocks non-compliant changes

[PR #1](https://github.com/gregorywilsonjr/cgeaz/pull/1) added a public, shared-key storage
account on purpose. The gate failed it, naming each rule and resource, and it was
closed unmerged. Branch protection requires all four gate checks on `main`, for
admins too.

```text
$ gh pr view 1 --repo "$GH_REPO" --json title,state,mergedAt,closedAt --jq "{title, state, mergedAt, closedAt}"
{"closedAt":"2026-09-20T03:47:46Z","mergedAt":null,"state":"CLOSED","title":"Gate test: public storage account (must fail)"}
```

```text
$ gh pr checks 1 --repo "$GH_REPO" || true
gate (01-foundation)	fail	23s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/35487380071/job/106016140631	
gate (03-evidence-store)	pass	54s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/35487380071/job/106016140693	
gate (04-reporting)	pass	52s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/35487380071/job/106016140698	
gate (06-enforcement)	pass	37s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/35487380071/job/106016140718	
```

```text
$ gh run view "$GATE_RUN" --repo "$GH_REPO" --log-failed | grep -E "FAIL|[0-9]+ tests?," | sed -E "s/^.*[0-9]Z //"
FAIL - stages/01-foundation/plan.json - main - azurerm_storage_account.gate_test: shared key access must be disabled (identity or nothing) — func runtime storage is the documented exception
FAIL - stages/01-foundation/plan.json - main - azurerm_storage_account.gate_test: storage accounts must not allow public blob access
4 tests, 2 passed, 0 warnings, 2 failures, 0 exceptions
```

```text
$ gh api "repos/$GH_REPO/branches/main/protection" --jq "{required_checks: .required_status_checks.contexts, enforce_admins: .enforce_admins.enabled}"
{"enforce_admins":true,"required_checks":["gate (01-foundation)","gate (03-evidence-store)","gate (04-reporting)","gate (06-enforcement)"]}
```

## 6. Repairs wait for a human, then run as the remediation identity

Stage 06 runs in dry-run: the Modify assignment doesn't enforce, so nothing changes until
a person creates a remediation task. Below: the assignment's mode, the task a person
created, and the writes to the seed account. The repair's caller is `REMEDIATION_PID`;
the sabotage before it and later fixes by hand show `<owner>`.

```text
$ az policy assignment show --name cge-fix-public-blob --scope /providers/Microsoft.Management/managementGroups/mg-grc-sandbox --query "{name:name, enforcementMode:enforcementMode}" -o table
Name                 EnforcementMode
-------------------  -----------------
cge-fix-public-blob  DoNotEnforce
```

```text
$ az policy remediation list --resource-group rg-grc-sandbox-dev --query "[].{name:name, state:provisioningState, created:createdOn, createdBy:systemData.createdBy, succeeded:deploymentStatus.successfulDeployments, failed:deploymentStatus.failedDeployments}" -o table
Name                        State      Created                           CreatedBy              Succeeded    Failed
--------------------------  ---------  --------------------------------  ---------------------  -----------  --------
fix-public-blob-1789871654  Succeeded  2026-09-20T02:34:16.504877+00:00  <owner>  1            0
```

```text
$ az monitor activity-log list --resource-id "$SEED_ID" --offset 89d --query "[?operationName.value=='Microsoft.Storage/storageAccounts/write' && status.value=='Succeeded'].{time:eventTimestamp, caller:caller}" -o table
Time                          Caller
----------------------------  ------------------------------------
2026-09-20T06:31:17.6419393Z  <owner>
2026-09-20T06:21:17.2792586Z  <owner>
2026-09-20T02:35:43.6468259Z  <owner>
2026-09-20T02:34:34.612041Z   c224b2bb-a300-413e-a666-525f7276beda
2026-09-20T02:25:44.4561185Z  <owner>
```

## 7. Drift detection in both directions

**Does Azure still match the code?** The nightly `drift-detection` workflow plans each
covered stage; a plan with changes opens an issue labeled `drift`.

```text
$ gh run list --repo "$GH_REPO" --workflow drift-detection --limit 14 --json createdAt,event,conclusion --jq ".[] | \"\(.createdAt)  \(.event)  \(.conclusion)\""
2026-09-20T03:38:28Z  workflow_dispatch  success
2026-09-20T03:23:27Z  workflow_dispatch  failure
2026-09-20T03:17:26Z  workflow_dispatch  failure
```

```text
$ gh issue list --repo "$GH_REPO" --label drift --state all --limit 20 || true
the 'gregorywilsonjr/cgeaz' repository has disabled issues
```

**Who is touching Azure?** Successful administrative writes and deletes over the last
7 days, by caller, from the Activity Log in `law-grc-sandbox`. The query is:
`AzureActivity | where TimeGenerated > ago(7d) | where CategoryValue == 'Administrative' and ActivityStatusValue in~ ('Success', 'Succeeded') | where OperationNameValue endswith '/WRITE' or OperationNameValue endswith '/DELETE' | summarize changes = count() by Caller | order by changes desc`

```text
$ az monitor log-analytics query --workspace "$WS_ID" --analytics-query "$KQL" -o table
Caller                                TableName      Changes
------------------------------------  -------------  ---------
<owner>                 PrimaryResult  75
c224b2bb-a300-413e-a666-525f7276beda  PrimaryResult  17
a6846247-77e6-4218-b713-508398a82650  PrimaryResult  10
```

## 8. Policy compliance right now

Counts by policy and state for the baseline initiative and the stage 06 repair policy,
then every resource my own three controls evaluate.

```text
$ az policy state list --filter "policyAssignmentName eq 'cge-grc-baseline' or policyAssignmentName eq 'cge-fix-public-blob'" --query "[].[policyDefinitionName, complianceState]" -o tsv | sort | uniq -c
      1 cge-cosmos-disable-local-auth	Compliant
      5 cge-deny-public-blob	Compliant
      5 cge-dine-storage-diagnostics	Compliant
      5 cge-fix-public-blob	Compliant
      3 cge-require-env-tag-rg	Compliant
      3 cge-require-owner-tag-rg	Compliant
      5 cge-storage-min-tls12	Compliant
```

```text
$ az policy state list --filter "policyDefinitionName eq 'cge-cosmos-disable-local-auth' or policyDefinitionName eq 'cge-require-owner-tag-rg' or policyDefinitionName eq 'cge-storage-min-tls12'" --query "[].{policy:policyDefinitionName, state:complianceState, evaluated:timestamp, resource:resourceId}" -o table
Policy                         State      Evaluated                         Resource
-----------------------------  ---------  --------------------------------  -----------------------------------------------------------------------------------------------------------------------------------------------------------------
cge-storage-min-tls12          Compliant  2026-09-20T06:51:33.115681+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-sandbox-dev/providers/microsoft.storage/storageaccounts/stgrcseed17735
cge-require-owner-tag-rg       Compliant  2026-09-20T06:22:55.165061+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-sandbox-dev
cge-storage-min-tls12          Compliant  2026-09-20T06:07:07.621907+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-tfstate/providers/microsoft.storage/storageaccounts/stgrctfstateedc399bb
cge-storage-min-tls12          Compliant  2026-09-20T06:05:19.140014+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcrpt871cp7
cge-storage-min-tls12          Compliant  2026-09-20T06:05:19.014283+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcfunc4obhbq
cge-storage-min-tls12          Compliant  2026-09-20T06:05:19.012482+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcevid4obhbq
cge-require-owner-tag-rg       Compliant  2026-09-20T06:05:17.666692+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-tfstate
cge-require-owner-tag-rg       Compliant  2026-09-20T06:05:17.658099+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev
cge-cosmos-disable-local-auth  Compliant  2026-09-20T06:05:14.681372+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.documentdb/databaseaccounts/cosmos-grc-evidence-4obhbq
```

The TLS finding on the hand-made seed account, before and after its fix, as saved at the time:

```text
== BEFORE fix: 2026-09-20T06:20:29Z
Account         MinTls
--------------  --------
stgrcseed17735  TLS1_0
Resource                                                                                                                                            State         Evaluated
--------------------------------------------------------------------------------------------------------------------------------------------------  ------------  --------------------------------
/subscriptions/<subscription-id>/resourcegroups/rg-grc-tfstate/providers/microsoft.storage/storageaccounts/stgrctfstateedc399bb  Compliant     2026-09-20T06:07:07.621907+00:00
/subscriptions/<subscription-id>/resourcegroups/rg-grc-sandbox-dev/providers/microsoft.storage/storageaccounts/stgrcseed17735    NonCompliant  2026-09-20T06:05:19.354650+00:00
/subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcrpt871cp7   Compliant     2026-09-20T06:05:19.140014+00:00
/subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcfunc4obhbq  Compliant     2026-09-20T06:05:19.014283+00:00
/subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcevid4obhbq  Compliant     2026-09-20T06:05:19.012482+00:00
== AFTER fix: 2026-09-20T06:26:55Z
Account         MinTls
--------------  --------
stgrcseed17735  TLS1_2
Resource                                                                                                                                            State      Evaluated
--------------------------------------------------------------------------------------------------------------------------------------------------  ---------  --------------------------------
/subscriptions/<subscription-id>/resourcegroups/rg-grc-sandbox-dev/providers/microsoft.storage/storageaccounts/stgrcseed17735    Compliant  2026-09-20T06:22:55.770858+00:00
/subscriptions/<subscription-id>/resourcegroups/rg-grc-tfstate/providers/microsoft.storage/storageaccounts/stgrctfstateedc399bb  Compliant  2026-09-20T06:07:07.621907+00:00
/subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcrpt871cp7   Compliant  2026-09-20T06:05:19.140014+00:00
/subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcfunc4obhbq  Compliant  2026-09-20T06:05:19.014283+00:00
/subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcevid4obhbq  Compliant  2026-09-20T06:05:19.012482+00:00
== Who made the change (Activity Log)
Time                          Caller                 Status
----------------------------  ---------------------  ---------
2026-09-20T06:21:17.2792586Z  <owner>  Succeeded
2026-09-20T06:21:16.7479786Z  <owner>  Started
```

## 9. What each pipeline identity is allowed to do

Live role assignments (control plane) for each pipeline identity, then the Cosmos
data-plane grants.

```text
$ az role assignment list --assignee "$COLLECTOR_PID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table
Role             Scope
---------------  ---------------------------------------------------
Security Reader  /subscriptions/<subscription-id>
```

```text
$ az role assignment list --assignee "$REPORTER_PID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table
Role                           Scope
-----------------------------  --------------------------------------------------------------------------------------------------------------------------------------------------
Storage Blob Data Contributor  /subscriptions/<subscription-id>/resourceGroups/rg-grc-evidence-dev/providers/Microsoft.Storage/storageAccounts/stgrcevid4obhbq
```

```text
$ az role assignment list --assignee "$REMEDIATION_PID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table
Role                         Scope
---------------------------  ---------------------------------------------------------------
Monitoring Contributor       /providers/Microsoft.Management/managementGroups/mg-grc-sandbox
Storage Account Contributor  /providers/Microsoft.Management/managementGroups/mg-grc-sandbox
```

```text
$ az role assignment list --assignee "$CI_SP_ID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table
Role                           Scope
-----------------------------  ---------------------------------------------------------------------------------
Storage Blob Data Contributor  /subscriptions/<subscription-id>/resourceGroups/rg-grc-tfstate
Contributor                    /providers/Microsoft.Management/managementGroups/mg-grc
```

```text
$ az cosmosdb sql role assignment list --account-name "$COSMOS_NAME" --resource-group rg-grc-evidence-dev --query "[].{principal:principalId, role:roleDefinitionId}" -o table
Principal                             Role
------------------------------------  -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
<my-object-id>  Cosmos DB Built-in Data Contributor
4449aee0-c619-42fe-89be-0f37bd221d84  Cosmos DB Built-in Data Reader
cacc0d2f-0990-475b-8c42-db353d394079  Cosmos DB Built-in Data Contributor
```
