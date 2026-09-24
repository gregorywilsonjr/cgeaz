#!/usr/bin/env bash
# Capture live evidence for the capstone into docs/EVIDENCE.md.
#
# Every block on that page is real output from this pipeline's subscription, printed under
# the command that produced it, so anyone with access can re-run the same commands and
# compare. Re-run this before submitting to refresh the page. Each run leaves one small WORM
# probe blob under reports/evidence/ that can't be deleted for 90 days; that is the WORM test.
#
# Privacy: the owner email (in every form Entra writes it), the subscription ID, the tenant ID
# and my Entra object ID become placeholders. The script refuses to write the page if any of
# them, a function key or a SAS signature is still in the output.
#
# Needs: az and gh signed in, every stage initialised (terraform init), TF_VAR_owner_email
# set, and a Python with azure-cosmos and azure-identity (the Lab 4 venv).
# Commands are kept as text (single-quoted on purpose) and run with eval, so each can be
# printed exactly as written above its output. That is also why some variables look unused.
# shellcheck disable=SC2016,SC2034
set -uo pipefail
export AZURE_CORE_ONLY_SHOW_ERRORS=true
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=yes_without_prompt

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/docs/EVIDENCE.md"
EMAIL="${TF_VAR_owner_email:?set TF_VAR_owner_email to your owner email first}"
GH_REPO="${GH_REPO:-$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}"

PY="${PYTHON:-python3}"
if ! "$PY" -c 'import azure.cosmos, azure.identity' 2>/dev/null; then
  PY="$HOME/cge-venv/bin/python3"
  if ! "$PY" -c 'import azure.cosmos, azure.identity' 2>/dev/null; then
    echo "No Python with azure-cosmos and azure-identity found. Activate the Lab 4 venv and re-run." >&2
    exit 1
  fi
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
RAW="$TMP/evidence.md"

tf_out() { (cd "$REPO_ROOT/stages/$1" && terraform output -raw "$2" 2>/dev/null); }

echo ">> Resolving names and identities"
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
ME_ID=$(az ad signed-in-user show --query id -o tsv)
STG=$(tf_out 03-evidence-store evidence_storage_account)
COSMOS_NAME=$(tf_out 03-evidence-store cosmos_account_name)
COSMOS_ENDPOINT=$(tf_out 03-evidence-store cosmos_endpoint)
COLLECTOR_PID=$(tf_out 03-evidence-store collector_principal_id)
REPORTER_PID=$(tf_out 04-reporting reporter_principal_id)
REMEDIATION_PID=$(tf_out 01-foundation remediation_identity_principal_id)
CI_APP_ID=$(az ad app list --display-name "github-cgeaz-${GH_REPO%%/*}" --query "[0].appId" -o tsv)
CI_SP_ID=$(az ad sp show --id "$CI_APP_ID" --query id -o tsv 2>/dev/null)
STATE_SA=$(az storage account list --resource-group rg-grc-tfstate --query "[0].name" -o tsv)
LAST_PR=$(gh pr list --repo "$GH_REPO" --state merged --limit 1 --json number --jq '.[0].number')
ALERT_ID=$(tf_out 01-foundation change_activity_alert_id)
for v in GH_REPO SUB_ID TENANT_ID ME_ID STG COSMOS_NAME COSMOS_ENDPOINT COLLECTOR_PID \
         REPORTER_PID REMEDIATION_PID CI_APP_ID CI_SP_ID STATE_SA LAST_PR ALERT_ID; do
  if [ -z "${!v}" ]; then
    echo "Could not resolve $v. Are az and gh signed in, and is every stage initialised?" >&2
    exit 1
  fi
done
export COSMOS_ENDPOINT

say() { printf '%s\n' "$@" >> "$RAW"; }
# block "command": a fenced block holding the command, then everything it printed.
block() {
  { printf '\n```text\n$ %s\n' "$1"; eval "$1" 2>&1; printf '```\n'; } >> "$RAW"
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
say "# Evidence" "" \
  "Live proof for the claims in the [README](../README.md#proof-points) and" \
  "[ARCHITECTURE.md](ARCHITECTURE.md). Every block below is real output from this" \
  "pipeline's subscription, captured at $NOW by" \
  "[\`scripts/capture-evidence.sh\`](../scripts/capture-evidence.sh). The first line of" \
  "each block is the command that produced it. The owner email, subscription ID, tenant" \
  "ID and my Entra object ID are replaced with placeholders." "" \
  "| Name used in the commands | Value |" \
  "|---|---|" \
  "| \`STG\` (evidence storage account) | \`$STG\` |" \
  "| \`COSMOS_NAME\` (evidence database account) | \`$COSMOS_NAME\` |" \
  "| \`GH_REPO\` | \`$GH_REPO\` |" \
  "| \`REMEDIATION_PID\` (\`id-grc-remediation-dev\`) | \`$REMEDIATION_PID\` |" \
  "| \`COLLECTOR_PID\` (collector Function) | \`$COLLECTOR_PID\` |" \
  "| \`REPORTER_PID\` (reporter Function) | \`$REPORTER_PID\` |" \
  "| \`CI_SP_ID\` (GitHub Actions; app ID \`$CI_APP_ID\`) | \`$CI_SP_ID\` |" \
  "| \`STATE_SA\` (Terraform state storage account) | \`$STATE_SA\` |"

echo ">> 1/10 WORM"
say "" "## 1. Reports can't be changed or deleted" "" \
  "The \`reports\` container has a time-based retention (WORM) policy. A new probe blob is" \
  "written, then deleting it and overwriting it are both refused, for every identity. The" \
  "last block shows the probe still there and never modified."
block 'az storage container immutability-policy show --account-name "$STG" --container-name reports --resource-group rg-grc-evidence-dev --query "{retentionDays:immutabilityPeriodSinceCreationInDays, state:state}" -o table'
PROBE="evidence/worm-probe-$(date -u +%Y%m%dT%H%M%SZ).txt"
echo "WORM probe written by scripts/capture-evidence.sh" > "$TMP/probe.txt"
echo "an attempt to overwrite the probe" > "$TMP/overwrite.txt"
block 'az storage blob upload --account-name "$STG" --container-name reports --name "$PROBE" --file "$TMP/probe.txt" --auth-mode login -o none && echo "uploaded $PROBE"'
block 'az storage blob delete --account-name "$STG" --container-name reports --name "$PROBE" --auth-mode login'
block 'az storage blob upload --account-name "$STG" --container-name reports --name "$PROBE" --file "$TMP/overwrite.txt" --auth-mode login --overwrite -o none'
block 'az storage blob show --account-name "$STG" --container-name reports --name "$PROBE" --auth-mode login --query "{name:name, created:properties.creationTime, lastModified:properties.lastModified}" -o table'

echo ">> 2/10 report trace (downloads every POA&M and SAR)"
say "" "## 2. Every report number traces to a stored query" "" \
  "Each report in the WORM container, re-checked against the evidence store today with its" \
  "own collection run:" \
  "\`SELECT VALUE COUNT(1) FROM c WHERE c.runId = @run AND c.status = 'Unhealthy'\`." \
  "The list is also the run history: one POA&M per day and one SAR per week since the" \
  "timers went live. The query runs as me, through the data-plane role stage 03 grants me." "" \
  "Reports written before the collector kept every run point at a run the store no longer" \
  "holds, so they cannot reproduce by construction. They are counted separately rather than" \
  "hidden: see [INCIDENT-001-REPORT-LINEAGE.md](INCIDENT-001-REPORT-LINEAGE.md)." ""
mkdir -p "$TMP/reports"
az storage blob download-batch --account-name "$STG" --auth-mode login --source reports \
  --destination "$TMP/reports" --pattern "poam/*.json" -o none >/dev/null
az storage blob download-batch --account-name "$STG" --auth-mode login --source reports \
  --destination "$TMP/reports" --pattern "sar/*.md" -o none >/dev/null
"$PY" - "$TMP/reports" >> "$RAW" 2>&1 <<'PY'
import glob, json, os, re, sys
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

root = sys.argv[1]
store = (CosmosClient(os.environ["COSMOS_ENDPOINT"], DefaultAzureCredential())
         .get_database_client("grc").get_container_client("assessments"))
query = "SELECT VALUE COUNT(1) FROM c WHERE c.runId = @run AND c.status = 'Unhealthy'"
held_query = "SELECT VALUE COUNT(1) FROM c WHERE c.runId = @run"
cache = {}
held_cache = {}

def store_count(run):
    if not run or run == "None":
        return None
    if run not in cache:
        cache[run] = sum(store.query_items(query, parameters=[{"name": "@run", "value": run}],
                                           enable_cross_partition_query=True))
    return cache[run]

rows = []
for path in glob.glob(os.path.join(root, "**", "*"), recursive=True):
    name = os.path.relpath(path, root)
    if name.endswith(".json"):
        with open(path) as f:
            doc = json.load(f)
        rows.append((name, doc.get("runId"), len(doc.get("items", []))))
    elif name.endswith(".md"):
        with open(path) as f:
            text = f.read()
        run = re.search(r"Collection run:\*\* `([^`]*)`", text)
        said = re.search(r"Open findings:\*\* (\d+)", text)
        rows.append((name, run.group(1) if run else None, int(said.group(1)) if said else None))

def run_held(run):
    """Does the store still hold the run this report was built from?

    Reports written before the collector kept every run point at a runId whose
    documents a later run overwrote. Those cannot reproduce by construction, so
    they are counted separately instead of as failures. The store decides which
    population a report is in - nothing here is hardcoded to a date.
    """
    if not run or run == "None":
        return False
    if run not in held_cache:
        held_cache[run] = sum(store.query_items(held_query, parameters=[{"name": "@run", "value": run}],
                                                enable_cross_partition_query=True)) > 0
    return held_cache[run]

def by_date(row):
    day = re.search(r"\d{4}-\d{2}-\d{2}", row[0])
    return (day.group(0) if day else "", row[0])

print("| Report | Collection run | Report says | Store query today | Run still held | Reproduces |")
print("|---|---|---|---|---|---|")
same = 0
held = 0
orphans = []
for name, run, said in sorted(rows, key=by_date):
    now = store_count(run)
    in_store = run_held(run)
    match = said is not None and now == said
    if in_store:
        held += 1
        same += match
    else:
        orphans.append(name)
    print(f"| `{name}` | `{run}` | {said} | {now} | {'yes' if in_store else 'no'} | {'yes' if match else 'no'} |")
print()
print(f"{same} of {held} reports whose collection run the store still holds reproduce from the store today.")
if orphans:
    noun = "report" if len(orphans) == 1 else "reports"
    verb = "was" if len(orphans) == 1 else "were"
    print(f"{len(orphans)} earlier {noun} {verb} built from a collection run the store no longer "
          "holds, before the collector kept every run. See docs/INCIDENT-001-REPORT-LINEAGE.md.")
PY

echo ">> 3/10 collection lineage"
say "" "## 3. Collection lineage" "" \
  "The newest collection run, what it wrote, and one of its documents with its run" \
  "stamps. Also the document count in each container." ""
"$PY" - >> "$RAW" 2>&1 <<'PY'
import collections, json, os
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

db = CosmosClient(os.environ["COSMOS_ENDPOINT"], DefaultAzureCredential()).get_database_client("grc")
store = db.get_container_client("assessments")

def rows(container, sql, run=None):
    params = [{"name": "@run", "value": run}] if run else None
    return list(container.query_items(sql, parameters=params, enable_cross_partition_query=True))

print("```text")
for name in ("assessments", "frameworks", "mappings"):
    count = sum(rows(db.get_container_client(name), "SELECT VALUE COUNT(1) FROM c"))
    print(f"{name:<12} {count} documents")
latest = rows(store, "SELECT TOP 1 c.runId, c.collectedAt FROM c ORDER BY c.collectedAt DESC")
if latest:
    run = latest[0]["runId"]
    docs = rows(store, "SELECT c.status, c.severity FROM c WHERE c.runId = @run", run)
    status = collections.Counter(str(d.get("status")) for d in docs)
    severity = collections.Counter(str(d.get("severity") or "Unknown") for d in docs
                                   if d.get("status") == "Unhealthy")
    print()
    print(f"newest run:   {run}")
    print(f"collected at: {latest[0]['collectedAt']}")
    print(f"documents:    {len(docs)}  by status: {dict(sorted(status.items()))}")
    print(f"unhealthy by severity: {dict(sorted(severity.items()))}")
print("```")
if latest:
    sample = rows(store, "SELECT TOP 1 c.id, c.runId, c.collectedAt, c.assessmentId, c.displayName, "
                         "c.status, c.severity, c.resourceId FROM c "
                         "WHERE c.runId = @run AND c.status = 'Unhealthy'", run)
    if sample:
        print()
        print("```json")
        print(json.dumps(sample[0], indent=2))
        print("```")
PY

say "" "**Every run the store still holds.** A night the collector wrote nothing leaves a gap" \
  "here rather than a wrong number: that day's POA&M names the run it was built from, which" \
  "is the one before it. Open findings rose from 33 to 54 on 2026-09-21, when Defender first" \
  "scanned the resources Labs 4 and 5 created, and fall again as fixes land." ""
"$PY" "$REPO_ROOT/labs/04-evidence/run_history.py" >> "$RAW" 2>&1

echo ">> 4/10 live deny tests"
say "" "## 4. The preventive controls fire" "" \
  "Two live attempts to create a storage account that breaks a Deny policy. The first" \
  "allows public blob access (\`cge-deny-public-blob\`); the second declares no minimum" \
  "TLS version (\`cge-storage-min-tls12\`). Azure refuses both and nothing is created." \
  "The last block is the other side of the TLS control: a tag-only update to the seed" \
  "account, which already declares TLS 1.2, still goes through."
STAMP=$(date -u +%m%d%H%M%S)
DENY_NAME="stgrcdeny$STAMP"
TLS_NAME="stgrctls$STAMP"
block 'az policy assignment show --name cge-grc-baseline --scope /providers/Microsoft.Management/managementGroups/mg-grc-sandbox --query "{publicBlob:parameters.publicBlobEffect.value, storageTls:parameters.storageTlsEffect.value}" -o table'
block 'az storage account create --name "$DENY_NAME" --resource-group rg-grc-sandbox-dev --location eastus --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access true -o none 2>&1 | head -n 12'
block 'az storage account create --name "$TLS_NAME" --resource-group rg-grc-sandbox-dev --location eastus --sku Standard_LRS --allow-blob-public-access false -o none 2>&1 | head -n 12'
SEED_NAME=$(az storage account list --resource-group rg-grc-sandbox-dev --query "[?starts_with(name, 'stgrcseed')].name | [0]" -o tsv)
block 'az storage account update --name "$SEED_NAME" --resource-group rg-grc-sandbox-dev --set tags.lastcheck="$STAMP" --query "{name:name, minTls:minimumTlsVersion, lastcheck:tags.lastcheck}" -o table'
for name in "$DENY_NAME" "$TLS_NAME"; do
  if az storage account show --name "$name" --resource-group rg-grc-sandbox-dev -o none 2>/dev/null; then
    az storage account delete --name "$name" --resource-group rg-grc-sandbox-dev --yes
    say "" "**\`$name\` was created, so its deny did not fire. It was deleted right away.**"
    echo "WARNING: the deny test created $name (now deleted). Check the Deny policies." >&2
  fi
done

echo ">> 5/10 CI gate"
GATE_RUN=$(gh run list --repo "$GH_REPO" --workflow compliance-gate --branch gate-test-public-storage \
  --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
say "" "## 5. The gate blocks non-compliant changes" "" \
  "[PR #1](https://github.com/$GH_REPO/pull/1) added a public, shared-key storage" \
  "account on purpose. The gate failed it, naming each rule and resource, and it was" \
  "closed unmerged. Branch protection requires every gate check on \`main\`, for" \
  "admins too."
block 'gh pr view 1 --repo "$GH_REPO" --json title,state,mergedAt,closedAt --jq "{title, state, mergedAt, closedAt}"'
block 'gh pr checks 1 --repo "$GH_REPO" || true'
block 'gh run view "$GATE_RUN" --repo "$GH_REPO" --log-failed | grep -E "FAIL|[0-9]+ tests?," | sed -E "s/^.*[0-9]Z //"'
block 'gh api "repos/$GH_REPO/branches/main/protection" --jq "{required_checks: .required_status_checks.contexts, enforce_admins: .enforce_admins.enabled}"'
say "" "Those same checks on the last pull request that did merge, #$LAST_PR. \`tier0\` runs the" \
  "half that needs no credentials (\`terraform fmt\` and \`validate\`, tflint, checkov and the" \
  "crosswalk check) and the gate matrix plans every stage as the GitHub identity."
block 'gh pr checks "$LAST_PR" --repo "$GH_REPO" || true'

echo ">> 6/10 remediation"
SEED_ID=$(az storage account list --resource-group rg-grc-sandbox-dev --query "[?starts_with(name, 'stgrcseed')].id | [0]" -o tsv)
say "" "## 6. Repairs wait for a human, then run as the remediation identity" "" \
  "Stage 06 runs in dry-run: the Modify assignment doesn't enforce, so nothing changes until" \
  "a person creates a remediation task. Below: the assignment's mode, the task a person" \
  "created, and the writes to the seed account. The repair's caller is \`REMEDIATION_PID\`;" \
  "the sabotage before it and later fixes by hand show \`<owner>\`."
block 'az policy assignment show --name cge-fix-public-blob --scope /providers/Microsoft.Management/managementGroups/mg-grc-sandbox --query "{name:name, enforcementMode:enforcementMode}" -o table'
block 'az policy remediation list --resource-group rg-grc-sandbox-dev --query "[].{name:name, state:provisioningState, created:createdOn, createdBy:systemData.createdBy, succeeded:deploymentStatus.successfulDeployments, failed:deploymentStatus.failedDeployments}" -o table'
block "az monitor activity-log list --resource-id \"\$SEED_ID\" --offset 89d --query \"[?operationName.value=='Microsoft.Storage/storageAccounts/write' && status.value=='Succeeded'].{time:eventTimestamp, caller:caller}\" -o table"

echo ">> 7/10 drift detection"
WS_ID=$(az monitor log-analytics workspace show --resource-group rg-grc-sandbox-dev --workspace-name law-grc-sandbox --query customerId -o tsv)
KQL="AzureActivity | where TimeGenerated > ago(7d) | where CategoryValue == 'Administrative' and ActivityStatusValue in~ ('Success', 'Succeeded') | where OperationNameValue endswith '/WRITE' or OperationNameValue endswith '/DELETE' | summarize changes = count() by Caller | order by changes desc"
say "" "## 7. Drift detection in both directions" "" \
  "**Does Azure still match the code?** The nightly \`drift-detection\` workflow plans all five" \
  "stages; a plan with changes opens an issue labeled \`drift\` and fails the run. Each red run" \
  "below is accounted for. The two oldest, both manual on 2026-09-20, failed at \`azure/login\`" \
  "with AADSTS700213: Entra had no federated credential yet matching GitHub's ID-based subject" \
  "claim, so the trust failed closed (see \"CI couldn't sign in\" in" \
  "[the README](../README.md#what-i-changed-from-the-course-starter)). The red run on 2026-09-21" \
  "is the controlled drift test: a tag added to \`law-grc-sandbox\` outside Terraform was caught," \
  "reported as issue #14 and removed through Terraform, and the run after it is clean. The green" \
  "manual runs are checks, not padding: the one after the drift test, and the one on 2026-09-22" \
  "that proved CI still reads Terraform state with the account's keys turned off."
block 'gh run list --repo "$GH_REPO" --workflow drift-detection --limit 30 --json createdAt,event,conclusion --jq ".[] | \"\(.createdAt)  \(.event)  \(.conclusion)\""'
block 'gh issue list --repo "$GH_REPO" --label drift --state all --limit 20 || true'
say "" "**Who is touching Azure?** Successful administrative writes and deletes over the last" \
  "7 days, by caller, from the Activity Log in \`law-grc-sandbox\`. The query is:" \
  "\`$KQL\`"
block 'az monitor log-analytics query --workspace "$WS_ID" --analytics-query "$KQL" -o table'
say "" "**The tripwire itself.** The alert runs that query every hour, emails the owner through" \
  "\`ag-grc-control-plane-changes\`, then stays quiet for six hours so a burst of changes sends" \
  "one message rather than ten. Its settings, then every time it fired in the last 30 days:" \
  "the last of them is the state account being hardened."
block 'az resource show --ids "$ALERT_ID" --query "{enabled:properties.enabled, frequency:properties.evaluationFrequency, window:properties.windowSize, severity:properties.severity, muteFor:properties.muteActionsDuration}" -o table'
block "az rest --method get --url \"https://management.azure.com/subscriptions/\$SUB_ID/providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&timeRange=30d\" --query \"sort_by(value[?contains(properties.essentials.alertRule, 'alert-grc-control-plane-changes')].{fired:properties.essentials.startDateTime, condition:properties.essentials.monitorCondition}, &fired)\" -o table"

echo ">> 8/10 policy compliance"
say "" "## 8. Policy compliance right now" "" \
  "Counts by policy and state for the baseline initiative and the stage 06 repair policy," \
  "then every resource my own three controls evaluate."
block "az policy state list --filter \"policyAssignmentName eq 'cge-grc-baseline' or policyAssignmentName eq 'cge-fix-public-blob'\" --query \"[].[policyDefinitionName, complianceState]\" -o tsv | sort | uniq -c"
block "az policy state list --filter \"policyDefinitionName eq 'cge-cosmos-disable-local-auth' or policyDefinitionName eq 'cge-require-owner-tag-rg' or policyDefinitionName eq 'cge-storage-min-tls12'\" --query \"[].{policy:policyDefinitionName, state:complianceState, evaluated:timestamp, resource:resourceId}\" -o table"
if [ -f "$HOME/control3-tls-evidence.txt" ]; then
  say "" "The TLS finding on the hand-made seed account, before and after its fix, as saved at the time:"
  { printf '\n```text\n'; cat "$HOME/control3-tls-evidence.txt"; printf '```\n'; } >> "$RAW"
fi

echo ">> 9/10 identity whitelists"
say "" "## 9. What each pipeline identity is allowed to do" "" \
  "Live role assignments (control plane) for each pipeline identity, then the Cosmos" \
  "data-plane grants and the Terraform state account's settings."
block 'az role assignment list --assignee "$COLLECTOR_PID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table'
block 'az role assignment list --assignee "$REPORTER_PID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table'
block 'az role assignment list --assignee "$REMEDIATION_PID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table'
block 'az role assignment list --assignee "$CI_SP_ID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table'
block 'az cosmosdb sql role assignment list --account-name "$COSMOS_NAME" --resource-group rg-grc-evidence-dev --query "[].{principal:principalId, role:roleDefinitionId}" -o table'
say "" "Terraform state accepts Entra ID sign-in only, so reading or writing it takes a blob" \
  "data role, like CI's Storage Blob Data Contributor above; the account's keys don't work." \
  "Every version of each state file is kept, and a deleted state file or the container can" \
  "be restored for 7 days."
block 'az storage account show --name "$STATE_SA" --resource-group rg-grc-tfstate --query "{sharedKeyAccess:allowSharedKeyAccess, minTls:minimumTlsVersion, publicBlobAccess:allowBlobPublicAccess}" -o table'
block 'az storage account blob-service-properties show --account-name "$STATE_SA" --resource-group rg-grc-tfstate --query "{versioning:isVersioningEnabled, blobSoftDeleteDays:deleteRetentionPolicy.days, containerSoftDeleteDays:containerDeleteRetentionPolicy.days}" -o table'

echo ">> 10/10 framework crosswalk"
say "" "## 10. The framework crosswalk is data, and it is checked" "" \
  "Every control in [CONTROLS.md](CONTROLS.md) is a row in the \`mappings\` container, seeded" \
  "by [\`seed_mappings.py\`](../labs/04-evidence/seed_mappings.py). Below is what" \
  "\`seed_mappings.py --report\` reads back: coverage by CSF 2.0 category, joined to the" \
  "category catalog in the \`frameworks\` container, then the checks. Every mapped category" \
  "must be in the catalog, every mapped control must point at a file that exists, and the" \
  "store must agree with CONTROLS.md category by category." ""
"$PY" "$REPO_ROOT/labs/04-evidence/seed_mappings.py" --report >> "$RAW" 2>&1

echo ">> Redacting and checking"
LOCAL="${EMAIL%@*}"
LOCAL_RE=$(printf '%s' "$LOCAL" | sed 's/[][\.*^$+?(){}|~]/\\&/g')
sed -E \
  -e "s~[A-Za-z0-9._%+#-]*${LOCAL_RE}[A-Za-z0-9._%+#-]*(@[A-Za-z0-9.-]+)?~<owner>~gI" \
  -e "s~${SUB_ID}~<subscription-id>~gI" \
  -e "s~${TENANT_ID}~<tenant-id>~gI" \
  -e "s~${ME_ID}~<my-object-id>~gI" \
  -e "s~[^ ]*/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001~Cosmos DB Built-in Data Reader~g" \
  -e "s~[^ ]*/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002~Cosmos DB Built-in Data Contributor~g" \
  "$RAW" > "$TMP/final.md"

for pattern in "$LOCAL" "$SUB_ID" "$TENANT_ID" "$ME_ID" "code=" "sig=" "AccountKey="; do
  if grep -qiF -- "$pattern" "$TMP/final.md"; then
    echo "STOPPED: a value that must not be published is still in the output; nothing was written." >&2
    exit 1
  fi
done

mv "$TMP/final.md" "$OUT"
echo
echo "Wrote docs/EVIDENCE.md ($(wc -l < "$OUT") lines)."
echo "  WORM refusals, expect 2 (the delete and the overwrite): $(grep -c 'BlobImmutableDueToPolicy' "$OUT")"
echo "  Deny refusals, expect 2 (one per test): $(grep -c '^Code: RequestDisallowedByPolicy' "$OUT")"
echo "  $(grep -E '^[0-9]+ of [0-9]+ reports whose collection run' "$OUT" || echo 'Report trace: no reports found')"
echo "  $(grep -E '^[0-9]+ controls mapped to |^The mappings container is empty' "$OUT" || echo 'Crosswalk: no coverage line')"
echo "  $(grep -E '^Crosswalk check passed|^The crosswalk check found problems' "$OUT" || echo 'Crosswalk check: no verdict')"
echo "Read it before you commit it."
