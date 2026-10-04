# Evidence

Live proof for the claims in the [README](../README.md#proof-points) and
[ARCHITECTURE.md](ARCHITECTURE.md). Every block below is real output from this
pipeline's subscription, captured at 2026-10-04T23:55:50Z by
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
| `STATE_SA` (Terraform state storage account) | `stgrctfstateedc399bb` |

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
uploaded evidence/worm-probe-20261004T235551Z.txt
```

```text
$ az storage blob delete --account-name "$STG" --container-name reports --name "$PROBE" --auth-mode login
ERROR: This operation is not permitted as the blob is immutable due to a policy.
RequestId:e0a61210-501e-006f-575b-546f63000000
Time:2026-10-04T23:55:53.8432662Z
ErrorCode:BlobImmutableDueToPolicy
```

```text
$ az storage blob upload --account-name "$STG" --container-name reports --name "$PROBE" --file "$TMP/overwrite.txt" --auth-mode login --overwrite -o none
ERROR: This operation is not permitted as the blob is immutable due to a policy.
RequestId:8997c7ef-801e-0053-2f5b-5446a4000000
Time:2026-10-04T23:55:54.7497186Z
ErrorCode:BlobImmutableDueToPolicy
If you want to overwrite the existing one, please add --overwrite in your command.
```

```text
$ az storage blob show --account-name "$STG" --container-name reports --name "$PROBE" --auth-mode login --query "{name:name, created:properties.creationTime, lastModified:properties.lastModified}" -o table
Name                                      Created                    LastModified
----------------------------------------  -------------------------  -------------------------
evidence/worm-probe-20261004T235551Z.txt  2026-10-04T23:55:52+00:00  2026-10-04T23:55:52+00:00
```

## 2. Every report number traces to a stored query

Each report in the WORM container, re-checked against the evidence store today with its
own collection run:
`SELECT VALUE COUNT(1) FROM c WHERE c.runId = @run AND c.status = 'Unhealthy'`.
The list is also the run history: one POA&M per day and one SAR per week since the
timers went live. The query runs as me, through the data-plane role stage 03 grants me.

Reports written before the collector kept every run point at a run the store no longer
holds, so they cannot reproduce by construction. They are counted separately rather than
hidden: see [INCIDENT-001-REPORT-LINEAGE.md](INCIDENT-001-REPORT-LINEAGE.md).

| Report | Collection run | Report says | Store query today | Run still held | Reproduces |
|---|---|---|---|---|---|
| `poam/2026/09/poam-2026-09-20.json` | `2ef7fe8c-4e43-4cf3-aa72-fa4aa2c0e91b` | 32 | 0 | no | no |
| `sar/2026/09/sar-2026-09-20.md` | `2ef7fe8c-4e43-4cf3-aa72-fa4aa2c0e91b` | 32 | 0 | no | no |
| `poam/2026/09/poam-2026-09-21.json` | `f6dd764d-e55c-4420-9ee7-2a2f49670bf2` | 54 | 54 | yes | yes |
| `sar/2026/09/sar-2026-09-21.md` | `f6dd764d-e55c-4420-9ee7-2a2f49670bf2` | 54 | 54 | yes | yes |
| `poam/2026/09/poam-2026-09-22.json` | `40e1919a-7da2-4bd9-ad96-94848bceda1e` | 54 | 54 | yes | yes |
| `poam/2026/09/poam-2026-09-23.json` | `40e1919a-7da2-4bd9-ad96-94848bceda1e` | 54 | 54 | yes | yes |
| `poam/2026/09/poam-2026-09-24.json` | `1273d608-553f-4d21-9431-8e7bd3349a6f` | 51 | 51 | yes | yes |
| `poam/2026/09/poam-2026-09-25.json` | `d8469d2f-748b-4660-9414-cbaedb94f8d0` | 51 | 51 | yes | yes |
| `poam/2026/09/poam-2026-09-26.json` | `231398fc-7425-4d0e-9eb6-a0a44d0a9c86` | 51 | 51 | yes | yes |
| `poam/2026/09/poam-2026-09-27.json` | `231398fc-7425-4d0e-9eb6-a0a44d0a9c86` | 51 | 51 | yes | yes |
| `poam/2026/09/poam-2026-09-28.json` | `5e134ccd-301d-4d7e-b17f-038071970985` | 51 | 51 | yes | yes |
| `sar/2026/09/sar-2026-09-28.md` | `5e134ccd-301d-4d7e-b17f-038071970985` | 51 | 51 | yes | yes |
| `poam/2026/09/poam-2026-09-29.json` | `a17aff07-05c9-4d55-bb37-499223216af9` | 51 | 51 | yes | yes |
| `poam/2026/09/poam-2026-09-30.json` | `788364c5-1b1f-41e5-9ac3-f315a74d4bcf` | 51 | 51 | yes | yes |
| `poam/2026/10/poam-2026-10-01.json` | `38d62326-b3a7-4148-bda3-57ce881b5bdd` | 51 | 51 | yes | yes |
| `poam/2026/10/poam-2026-10-02.json` | `2994e526-ad22-47f5-b87f-e5fedabf15ad` | 51 | 51 | yes | yes |
| `poam/2026/10/poam-2026-10-03.json` | `ab011446-8785-49e6-821c-62e34465a7de` | 51 | 51 | yes | yes |
| `poam/2026/10/poam-2026-10-04.json` | `3cd42ced-cc16-4c3e-b7fc-93545cf99d4d` | 51 | 51 | yes | yes |

16 of 16 reports whose collection run the store still holds reproduce from the store today.
2 earlier reports were built from a collection run the store no longer holds, before the collector kept every run. See docs/INCIDENT-001-REPORT-LINEAGE.md.

## 3. Collection lineage

The newest collection run, what it wrote, and one of its documents with its run
stamps. Also the document count in each container.

```text
assessments  1336 documents
frameworks   7 documents
mappings     30 documents

newest run:   3cd42ced-cc16-4c3e-b7fc-93545cf99d4d
collected at: 2026-10-04T05:00:01.110707+00:00
documents:    102  by status: {'Healthy': 45, 'NotApplicable': 6, 'Unhealthy': 51}
unhealthy by severity: {'High': 5, 'Low': 16, 'Medium': 19, 'Unknown': 11}
```

```json
{
  "id": "dc8f6afd258f9f2f32611d7412f174f3",
  "runId": "3cd42ced-cc16-4c3e-b7fc-93545cf99d4d",
  "collectedAt": "2026-10-04T05:00:01.110707+00:00",
  "assessmentId": "cdc78c07-02b0-4af0-1cb2-cb7c672a8b0a",
  "displayName": "Storage account should use a private link connection",
  "status": "Unhealthy",
  "severity": "Medium",
  "resourceId": "/subscriptions/<subscription-id>/resourcegroups/rg-grc-sandbox-dev/providers/microsoft.storage/storageaccounts/stgrcseed17735"
}
```

**Every run the store still holds.** A night the collector wrote nothing leaves a gap
here rather than a wrong number: that day's POA&M names the run it was built from, which
is the one before it. Open findings rose from 33 to 54 on 2026-09-21, when Defender first
scanned the resources Labs 4 and 5 created, and fall again as fixes land.

14 collection runs retained, 1336 documents in all.

| Collected (UTC) | Run | Documents | Open findings |
|---|---|---|---|
| 2026-09-20T05:00:00 | `297f9d16` | 58 | 33 |
| 2026-09-20T07:45:50 | `be9b5dc2` | 58 | 33 |
| 2026-09-21T05:00:01 | `f6dd764d` | 100 | 54 |
| 2026-09-22T05:00:01 | `40e1919a` | 100 | 54 |
| 2026-09-24T05:00:01 | `1273d608` | 102 | 51 |
| 2026-09-25T05:00:01 | `d8469d2f` | 102 | 51 |
| 2026-09-26T05:00:00 | `231398fc` | 102 | 51 |
| 2026-09-28T05:00:01 | `5e134ccd` | 102 | 51 |
| 2026-09-29T05:00:04 | `a17aff07` | 102 | 51 |
| 2026-09-30T05:00:00 | `788364c5` | 102 | 51 |
| 2026-10-01T05:00:24 | `38d62326` | 102 | 51 |
| 2026-10-02T05:00:01 | `2994e526` | 102 | 51 |
| 2026-10-03T05:00:01 | `ab011446` | 102 | 51 |
| 2026-10-04T05:00:01 | `3cd42ced` | 102 | 51 |

What changed from one run to the next:

| From | To | Findings closed | Findings opened |
|---|---|---|---|
| 2026-09-20 | 2026-09-20 | 0 | 0 |
| 2026-09-20 | 2026-09-21 | 1 | 22 |
| 2026-09-21 | 2026-09-22 | 0 | 0 |
| 2026-09-22 | 2026-09-24 | 3 | 0 |
| 2026-09-24 | 2026-09-25 | 0 | 0 |
| 2026-09-25 | 2026-09-26 | 0 | 0 |
| 2026-09-26 | 2026-09-28 | 0 | 0 |
| 2026-09-28 | 2026-09-29 | 0 | 0 |
| 2026-09-29 | 2026-09-30 | 0 | 0 |
| 2026-09-30 | 2026-10-01 | 0 | 0 |
| 2026-10-01 | 2026-10-02 | 0 | 0 |
| 2026-10-02 | 2026-10-03 | 0 | 0 |
| 2026-10-03 | 2026-10-04 | 0 | 0 |

Every finding that closed while these runs were kept, and the run that first reported it fixed:

- 2026-09-21: Security Center standard pricing tier should be selected on `keyvaults`
- 2026-09-24: Function App should only be accessible over HTTPS on `func-grc-collectors-4obhbq`
- 2026-09-24: Function App should only be accessible over HTTPS on `func-grc-reporting-871cp7`
- 2026-09-24: Storage accounts should prevent shared key access on `stgrctfstateedc399bb`

## 4. The preventive controls fire

Two live attempts to create a storage account that breaks a Deny policy. The first
allows public blob access (`cge-deny-public-blob`); the second declares no minimum
TLS version (`cge-storage-min-tls12`). Azure refuses both and nothing is created.
The last block is the other side of the TLS control: a tag-only update to the seed
account, which already declares TLS 1.2, still goes through.

```text
$ az policy assignment show --name cge-grc-baseline --scope /providers/Microsoft.Management/managementGroups/mg-grc-sandbox --query "{publicBlob:parameters.publicBlobEffect.value, storageTls:parameters.storageTlsEffect.value}" -o table
PublicBlob    StorageTls
------------  ------------
Deny          Deny
```

```text
$ az storage account create --name "$DENY_NAME" --resource-group rg-grc-sandbox-dev --location eastus --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access true -o none 2>&1 | head -n 12
ERROR: (RequestDisallowedByPolicy) Resource 'stgrcdeny1004235619' was disallowed by policy. Policy identifiers: '[{"policyAssignment":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyAssignments/cge-grc-baseline"},"policyDefinition":{"name":"Storage accounts must not allow public blob access","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyDefinitions/cge-deny-public-blob","version":"1.0.0"},"policySetDefinition":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policySetDefinitions/cge-grc-baseline","version":"1.0.0"}}]'.
Code: RequestDisallowedByPolicy
Message: Resource 'stgrcdeny1004235619' was disallowed by policy. Policy identifiers: '[{"policyAssignment":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyAssignments/cge-grc-baseline"},"policyDefinition":{"name":"Storage accounts must not allow public blob access","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyDefinitions/cge-deny-public-blob","version":"1.0.0"},"policySetDefinition":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policySetDefinitions/cge-grc-baseline","version":"1.0.0"}}]'.
Target: stgrcdeny1004235619
Additional Information:Type: PolicyViolation
Info: {
    "evaluationDetails": {
        "evaluatedExpressions": [
            {
                "result": "True",
                "expressionKind": "Field",
                "expression": "type",
```

```text
$ az storage account create --name "$TLS_NAME" --resource-group rg-grc-sandbox-dev --location eastus --sku Standard_LRS --allow-blob-public-access false -o none 2>&1 | head -n 12
ERROR: (RequestDisallowedByPolicy) Resource 'stgrctls1004235619' was disallowed by policy. Policy identifiers: '[{"policyAssignment":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyAssignments/cge-grc-baseline"},"policyDefinition":{"name":"Storage accounts must require TLS 1.2 or newer","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyDefinitions/cge-storage-min-tls12","version":"1.0.0"},"policySetDefinition":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policySetDefinitions/cge-grc-baseline","version":"1.0.0"}}]'.
Code: RequestDisallowedByPolicy
Message: Resource 'stgrctls1004235619' was disallowed by policy. Policy identifiers: '[{"policyAssignment":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyAssignments/cge-grc-baseline"},"policyDefinition":{"name":"Storage accounts must require TLS 1.2 or newer","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policyDefinitions/cge-storage-min-tls12","version":"1.0.0"},"policySetDefinition":{"name":"CGE-AZ GRC Baseline","id":"/providers/Microsoft.Management/managementGroups/mg-grc-sandbox/providers/Microsoft.Authorization/policySetDefinitions/cge-grc-baseline","version":"1.0.0"}}]'.
Target: stgrctls1004235619
Additional Information:Type: PolicyViolation
Info: {
    "evaluationDetails": {
        "evaluatedExpressions": [
            {
                "result": "True",
                "expressionKind": "Field",
                "expression": "type",
```

```text
$ az storage account update --name "$SEED_NAME" --resource-group rg-grc-sandbox-dev --set tags.lastcheck="$STAMP" --query "{name:name, minTls:minimumTlsVersion, lastcheck:tags.lastcheck}" -o table
Name            MinTls    Lastcheck
--------------  --------  -----------
stgrcseed17735  TLS1_2    1004235619
```

## 5. The gate blocks non-compliant changes

[PR #1](https://github.com/gregorywilsonjr/cgeaz/pull/1) added a public, shared-key storage
account on purpose. The gate failed it, naming each rule and resource, and it was
closed unmerged. Branch protection requires every gate check on `main`, for
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
{"enforce_admins":true,"required_checks":["gate (01-foundation)","gate (03-evidence-store)","gate (04-reporting)","gate (06-enforcement)","gate (02-activation)","tier0"]}
```

Those same checks on the last pull request that did merge, #24. `tier0` runs the
half that needs no credentials (`terraform fmt` and `validate`, tflint, checkov and the
crosswalk check) and the gate matrix plans every stage as the GitHub identity.

```text
$ gh pr checks "$LAST_PR" --repo "$GH_REPO" || true
gate (01-foundation)	pass	31s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/36514538222/job/109233797980	
gate (02-activation)	pass	31s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/36514538222/job/109233798195	
gate (03-evidence-store)	pass	55s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/36514538222/job/109233798065	
gate (04-reporting)	pass	49s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/36514538222/job/109233798096	
gate (06-enforcement)	pass	34s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/36514538222/job/109233798165	
guides	pass	8s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/36514538289/job/109233798283	
tier0	pass	49s	https://github.com/gregorywilsonjr/cgeaz/actions/runs/36514538222/job/109233797806	
parse-canary	skipping	0	https://github.com/gregorywilsonjr/cgeaz/actions/runs/36514538289/job/109233799378	
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
$ az monitor activity-log list --resource-id "$SEED_ID" --offset 89d --max-events 2000 --query "[?operationName.value=='Microsoft.Storage/storageAccounts/write' && status.value=='Succeeded'].{time:eventTimestamp, caller:caller}" -o table
Time                          Caller
----------------------------  ------------------------------------
2026-10-04T23:49:59.3349797Z  <owner>
2026-09-29T02:45:14.9932027Z  <owner>
2026-09-29T02:35:14.8816313Z  <owner>
2026-09-21T18:21:06.6323022Z  <owner>
2026-09-21T18:11:06.4889876Z  <owner>
2026-09-21T17:02:26.3621047Z  <owner>
2026-09-21T16:52:26.4412809Z  <owner>
2026-09-20T08:51:16.625313Z   <owner>
2026-09-20T08:41:16.5693158Z  <owner>
2026-09-20T06:31:17.6419393Z  <owner>
2026-09-20T06:21:17.2792586Z  <owner>
2026-09-20T02:35:43.6468259Z  <owner>
2026-09-20T02:34:34.612041Z   c224b2bb-a300-413e-a666-525f7276beda
2026-09-20T02:25:44.4561185Z  <owner>
2026-09-18T03:52:52.4696355Z  <owner>
```

## 7. Drift detection in both directions

**Does Azure still match the code?** The nightly `drift-detection` workflow plans all five
stages; a plan with changes opens an issue labeled `drift` and fails the run. Each red run
below is accounted for. The two oldest, both manual on 2026-09-20, failed at `azure/login`
with AADSTS700213: Entra had no federated credential yet matching GitHub's ID-based subject
claim, so the trust failed closed (see "CI couldn't sign in" in
[the README](../README.md#what-i-changed-from-the-course-starter)). The red run on 2026-09-21
is the controlled drift test: a tag added to `law-grc-sandbox` outside Terraform was caught,
reported as issue #14 and removed through Terraform, and the run after it is clean. The green
manual runs are checks, not padding: the one after the drift test, and the one on 2026-09-22
that proved CI still reads Terraform state with the account's keys turned off.

```text
$ gh run list --repo "$GH_REPO" --workflow drift-detection --limit 30 --json createdAt,event,conclusion --jq ".[] | \"\(.createdAt)  \(.event)  \(.conclusion)\""
2026-10-04T13:50:58Z  schedule  success
2026-10-03T13:12:19Z  schedule  success
2026-10-02T14:36:55Z  schedule  success
2026-10-01T15:17:18Z  schedule  success
2026-09-30T14:47:18Z  schedule  success
2026-09-29T14:44:54Z  schedule  success
2026-09-28T16:38:26Z  schedule  success
2026-09-27T13:44:56Z  schedule  success
2026-09-26T12:52:29Z  schedule  success
2026-09-25T13:29:45Z  schedule  success
2026-09-24T13:26:08Z  schedule  success
2026-09-23T13:30:49Z  schedule  success
2026-09-22T13:16:08Z  schedule  success
2026-09-22T07:35:45Z  workflow_dispatch  success
2026-09-21T18:00:37Z  workflow_dispatch  success
2026-09-21T17:55:45Z  workflow_dispatch  failure
2026-09-21T14:59:00Z  schedule  success
2026-09-20T12:58:04Z  schedule  success
2026-09-20T03:38:28Z  workflow_dispatch  success
2026-09-20T03:23:27Z  workflow_dispatch  failure
2026-09-20T03:17:26Z  workflow_dispatch  failure
```

```text
$ gh issue list --repo "$GH_REPO" --label drift --state all --limit 20 || true
14	CLOSED	Drift detected: stages/01-foundation (2026-09-21)	drift	2026-09-21T18:01:44Z
```

**Who is touching Azure?** Successful administrative writes and deletes over the last
7 days, by caller, from the Activity Log in `law-grc-sandbox`. The query is:
`AzureActivity | where TimeGenerated > ago(7d) | where CategoryValue == 'Administrative' and ActivityStatusValue in~ ('Success', 'Succeeded') | where OperationNameValue endswith '/WRITE' or OperationNameValue endswith '/DELETE' | summarize changes = count() by Caller | order by changes desc`

```text
$ az monitor log-analytics query --workspace "$WS_ID" --analytics-query "$KQL" -o table
Caller                 TableName      Changes
---------------------  -------------  ---------
<owner>  PrimaryResult  3
```

**The tripwire itself.** The alert runs that query every hour, emails the owner through
`ag-grc-control-plane-changes`, then stays quiet for six hours so a burst of changes sends
one message rather than ten. Its settings, then every time it fired in the last 30 days.
Each fire lines up with a change somebody made on purpose: the four on 2026-09-21 and
2026-09-22 are this pipeline being built, the last of them the state account being
hardened. Any fire after those is the tag-only update every evidence capture makes (section 4), which
is the alert doing its job.

```text
$ az resource show --ids "$ALERT_ID" --query "{enabled:properties.enabled, frequency:properties.evaluationFrequency, window:properties.windowSize, severity:properties.severity, muteFor:properties.muteActionsDuration}" -o table
Enabled    Frequency    Window    Severity    MuteFor
---------  -----------  --------  ----------  ---------
True       PT1H         PT1H      3           PT6H
```

```text
$ az rest --method get --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&timeRange=30d" --query "sort_by(value[?contains(properties.essentials.alertRule, 'alert-grc-control-plane-changes')].{fired:properties.essentials.startDateTime, condition:properties.essentials.monitorCondition}, &fired)" -o table
Fired                         Condition
----------------------------  -----------
2026-09-21T19:06:36.3726444Z  Fired
2026-09-21T20:06:38.0837385Z  Fired
2026-09-22T02:06:37.2335611Z  Fired
2026-09-22T08:06:34.0533676Z  Fired
2026-09-29T03:06:41.3408708Z  Fired
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
cge-storage-min-tls12          Compliant  2026-10-04T02:54:14.550651+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-tfstate/providers/microsoft.storage/storageaccounts/stgrctfstateedc399bb
cge-storage-min-tls12          Compliant  2026-10-04T02:54:14.159527+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-sandbox-dev/providers/microsoft.storage/storageaccounts/stgrcseed17735
cge-storage-min-tls12          Compliant  2026-10-04T02:54:14.020232+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcrpt871cp7
cge-storage-min-tls12          Compliant  2026-10-04T02:54:13.930277+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcfunc4obhbq
cge-storage-min-tls12          Compliant  2026-10-04T02:54:13.656146+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.storage/storageaccounts/stgrcevid4obhbq
cge-require-owner-tag-rg       Compliant  2026-10-04T02:54:11.967551+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-tfstate
cge-require-owner-tag-rg       Compliant  2026-10-04T02:54:11.965555+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-sandbox-dev
cge-require-owner-tag-rg       Compliant  2026-10-04T02:54:11.963541+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev
cge-cosmos-disable-local-auth  Compliant  2026-10-04T02:54:09.459796+00:00  /subscriptions/<subscription-id>/resourcegroups/rg-grc-evidence-dev/providers/microsoft.documentdb/databaseaccounts/cosmos-grc-evidence-4obhbq
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
data-plane grants and the Terraform state account's settings.

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

Terraform state accepts Entra ID sign-in only, so reading or writing it takes a blob
data role, like CI's Storage Blob Data Contributor above; the account's keys don't work.
Every version of each state file is kept, and a deleted state file or the container can
be restored for 7 days.

```text
$ az storage account show --name "$STATE_SA" --resource-group rg-grc-tfstate --query "{sharedKeyAccess:allowSharedKeyAccess, minTls:minimumTlsVersion, publicBlobAccess:allowBlobPublicAccess}" -o table
SharedKeyAccess    MinTls    PublicBlobAccess
-----------------  --------  ------------------
False              TLS1_2    False
```

```text
$ az storage account blob-service-properties show --account-name "$STATE_SA" --resource-group rg-grc-tfstate --query "{versioning:isVersioningEnabled, blobSoftDeleteDays:deleteRetentionPolicy.days, containerSoftDeleteDays:containerDeleteRetentionPolicy.days}" -o table
Versioning    BlobSoftDeleteDays    ContainerSoftDeleteDays
------------  --------------------  -------------------------
True          7                     7
```

## 10. The framework crosswalk is data, and it is checked

Every control in [CONTROLS.md](CONTROLS.md) is a row in the `mappings` container, seeded
by [`seed_mappings.py`](../labs/04-evidence/seed_mappings.py). Below is what
`seed_mappings.py --report` reads back: coverage by CSF 2.0 category, joined to the
category catalog in the `frameworks` container, then the checks. Every mapped category
must be in the catalog, every mapped control must point at a file that exists, and the
store must agree with CONTROLS.md category by category.

30 controls mapped to 13 of the 22 NIST CSF 2.0 categories.

| Function | Category | Controls | Which |
|---|---|---|---|
| Govern | GV.RM | 1 | `generate-poam` |
| Govern | GV.RR | 4 | `cge-require-owner-tag-rg`, `collector-reporter-separation`, `id-grc-remediation-dev`, `remediation-mode` |
| Govern | GV.PO | 3 | `compliance-gate-branch-protection`, `mg-grc-sandbox-initiative-assignment`, `remediation-mode` |
| Govern | GV.OV | 5 | `capture-evidence`, `csf-crosswalk`, `generate-sar`, `grc-evidence-database`, `nist-csf-20-standard` |
| Identify | ID.AM | 2 | `cge-require-env-tag-rg`, `cge-require-owner-tag-rg` |
| Identify | ID.RA | 5 | `collect-assessments`, `defender-plans-storage-keyvault`, `generate-sar`, `grc-evidence-database`, `nist-csf-20-standard` |
| Identify | ID.IM | 1 | `generate-poam` |
| Protect | PR.AA | 6 | `broad-roles-rego`, `cge-cosmos-disable-local-auth`, `collector-reporter-separation`, `id-grc-remediation-dev`, `identity-only-evidence-access`, `terraform-state-storage` |
| Protect | PR.DS | 7 | `cge-cosmos-disable-local-auth`, `cge-deny-public-blob`, `cge-fix-public-blob`, `cge-storage-min-tls12`, `storage-rego`, `terraform-state-storage`, `worm-reports-container` |
| Protect | PR.PS | 6 | `activity-log-to-workspace`, `cge-dine-storage-diagnostics`, `compliance-gate-branch-protection`, `mg-grc-sandbox-initiative-assignment`, `policy-identity-rego`, `tier0-static-checks` |
| Detect | DE.CM | 6 | `activity-log-to-workspace`, `cge-dine-storage-diagnostics`, `collect-assessments`, `control-plane-change-alert`, `defender-plans-storage-keyvault`, `terraform-drift` |
| Detect | DE.AE | 1 | `control-plane-change-alert` |
| Respond | RS.MI | 1 | `cge-fix-public-blob` |

No control in this repo maps to GV.OC, GV.SC, PR.AT, PR.IR, RS.MA, RS.AN, RS.CO, RC.RP, RC.CO.

Crosswalk check passed: the store agrees with CONTROLS.md category by category, every category is in the stored catalog, and every mapped control points at one of 18 files that exist in this repo.
