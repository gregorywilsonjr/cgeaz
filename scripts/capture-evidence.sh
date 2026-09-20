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
for v in GH_REPO SUB_ID TENANT_ID ME_ID STG COSMOS_NAME COSMOS_ENDPOINT COLLECTOR_PID \
         REPORTER_PID REMEDIATION_PID CI_APP_ID CI_SP_ID; do
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
  "| \`CI_SP_ID\` (GitHub Actions; app ID \`$CI_APP_ID\`) | \`$CI_SP_ID\` |"

echo ">> 1/9 WORM"
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

echo ">> 2/9 report trace (downloads every POA&M and SAR)"
say "" "## 2. Every report number traces to a stored query" "" \
  "Each report in the WORM container, re-checked against the evidence store today with its" \
  "own collection run:" \
  "\`SELECT VALUE COUNT(1) FROM c WHERE c.runId = @run AND c.status = 'Unhealthy'\`." \
  "The list is also the run history: one POA&M per day and one SAR per week since the" \
  "timers went live. The query runs as me, through the data-plane role stage 03 grants me." ""
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
cache = {}

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

def by_date(row):
    day = re.search(r"\d{4}-\d{2}-\d{2}", row[0])
    return (day.group(0) if day else "", row[0])

print("| Report | Collection run | Report says | Store query today | Reproduces |")
print("|---|---|---|---|---|")
same = 0
for name, run, said in sorted(rows, key=by_date):
    now = store_count(run)
    match = said is not None and now == said
    same += match
    print(f"| `{name}` | `{run}` | {said} | {now} | {'yes' if match else 'no'} |")
print()
print(f"{same} of {len(rows)} reports reproduce from the store today.")
if same < len(rows):
    print("A report that doesn't reproduce was built from documents that a later collection run overwrote.")
PY

echo ">> 3/9 collection lineage"
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

echo ">> 4/9 live deny test"
say "" "## 4. The preventive control fires" "" \
  "A live attempt to create a storage account that allows public blob access." \
  "\`cge-deny-public-blob\` is at Deny, so Azure refuses the request and nothing is created."
DENY_NAME="stgrcdeny$(date -u +%m%d%H%M%S)"
block 'az policy assignment show --name cge-grc-baseline --scope /providers/Microsoft.Management/managementGroups/mg-grc-sandbox --query "parameters.publicBlobEffect.value" -o tsv'
block 'az storage account create --name "$DENY_NAME" --resource-group rg-grc-sandbox-dev --location eastus --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access true -o none 2>&1 | head -n 12'
if az storage account show --name "$DENY_NAME" --resource-group rg-grc-sandbox-dev -o none 2>/dev/null; then
  az storage account delete --name "$DENY_NAME" --resource-group rg-grc-sandbox-dev --yes
  say "" "**The account was created, so the deny did not fire. It was deleted right away.**"
  echo "WARNING: the deny test created $DENY_NAME (now deleted). Check cge-deny-public-blob." >&2
fi

echo ">> 5/9 CI gate"
GATE_RUN=$(gh run list --repo "$GH_REPO" --workflow compliance-gate --branch gate-test-public-storage \
  --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
say "" "## 5. The gate blocks non-compliant changes" "" \
  "[PR #1](https://github.com/$GH_REPO/pull/1) added a public, shared-key storage" \
  "account on purpose. The gate failed it, naming each rule and resource, and it was" \
  "closed unmerged. Branch protection requires all four gate checks on \`main\`, for" \
  "admins too."
block 'gh pr view 1 --repo "$GH_REPO" --json title,state,mergedAt,closedAt --jq "{title, state, mergedAt, closedAt}"'
block 'gh pr checks 1 --repo "$GH_REPO" || true'
block 'gh run view "$GATE_RUN" --repo "$GH_REPO" --log-failed | grep -E "FAIL|[0-9]+ tests?," | sed -E "s/^.*[0-9]Z //"'
block 'gh api "repos/$GH_REPO/branches/main/protection" --jq "{required_checks: .required_status_checks.contexts, enforce_admins: .enforce_admins.enabled}"'

echo ">> 6/9 remediation"
SEED_ID=$(az storage account list --resource-group rg-grc-sandbox-dev --query "[?starts_with(name, 'stgrcseed')].id | [0]" -o tsv)
say "" "## 6. Repairs wait for a human, then run as the remediation identity" "" \
  "Stage 06 runs in dry-run: the Modify assignment doesn't enforce, so nothing changes until" \
  "a person creates a remediation task. Below: the assignment's mode, the task a person" \
  "created, and the writes to the seed account. The repair's caller is \`REMEDIATION_PID\`;" \
  "the sabotage before it and later fixes by hand show \`<owner>\`."
block 'az policy assignment show --name cge-fix-public-blob --scope /providers/Microsoft.Management/managementGroups/mg-grc-sandbox --query "{name:name, enforcementMode:enforcementMode}" -o table'
block 'az policy remediation list --resource-group rg-grc-sandbox-dev --query "[].{name:name, state:provisioningState, created:createdOn, createdBy:systemData.createdBy, succeeded:deploymentStatus.successfulDeployments, failed:deploymentStatus.failedDeployments}" -o table'
block "az monitor activity-log list --resource-id \"\$SEED_ID\" --offset 89d --query \"[?operationName.value=='Microsoft.Storage/storageAccounts/write' && status.value=='Succeeded'].{time:eventTimestamp, caller:caller}\" -o table"

echo ">> 7/9 drift detection"
WS_ID=$(az monitor log-analytics workspace show --resource-group rg-grc-sandbox-dev --workspace-name law-grc-sandbox --query customerId -o tsv)
KQL="AzureActivity | where TimeGenerated > ago(7d) | where CategoryValue == 'Administrative' and ActivityStatusValue in~ ('Success', 'Succeeded') | where OperationNameValue endswith '/WRITE' or OperationNameValue endswith '/DELETE' | summarize changes = count() by Caller | order by changes desc"
say "" "## 7. Drift detection in both directions" "" \
  "**Does Azure still match the code?** The nightly \`drift-detection\` workflow plans each" \
  "covered stage; a plan with changes opens an issue labeled \`drift\`."
block 'gh run list --repo "$GH_REPO" --workflow drift-detection --limit 14 --json createdAt,event,conclusion --jq ".[] | \"\(.createdAt)  \(.event)  \(.conclusion)\""'
block 'gh issue list --repo "$GH_REPO" --label drift --state all --limit 20 || true'
say "" "**Who is touching Azure?** Successful administrative writes and deletes over the last" \
  "7 days, by caller, from the Activity Log in \`law-grc-sandbox\`. The query is:" \
  "\`$KQL\`"
block 'az monitor log-analytics query --workspace "$WS_ID" --analytics-query "$KQL" -o table'

echo ">> 8/9 policy compliance"
say "" "## 8. Policy compliance right now" "" \
  "Counts by policy and state for the baseline initiative and the stage 06 repair policy," \
  "then every resource my own three controls evaluate."
block "az policy state list --filter \"policyAssignmentName eq 'cge-grc-baseline' or policyAssignmentName eq 'cge-fix-public-blob'\" --query \"[].[policyDefinitionName, complianceState]\" -o tsv | sort | uniq -c"
block "az policy state list --filter \"policyDefinitionName eq 'cge-cosmos-disable-local-auth' or policyDefinitionName eq 'cge-require-owner-tag-rg' or policyDefinitionName eq 'cge-storage-min-tls12'\" --query \"[].{policy:policyDefinitionName, state:complianceState, evaluated:timestamp, resource:resourceId}\" -o table"
if [ -f "$HOME/control3-tls-evidence.txt" ]; then
  say "" "The TLS finding on the hand-made seed account, before and after its fix, as saved at the time:"
  { printf '\n```text\n'; cat "$HOME/control3-tls-evidence.txt"; printf '```\n'; } >> "$RAW"
fi

echo ">> 9/9 identity whitelists"
say "" "## 9. What each pipeline identity is allowed to do" "" \
  "Live role assignments (control plane) for each pipeline identity, then the Cosmos" \
  "data-plane grants."
block 'az role assignment list --assignee "$COLLECTOR_PID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table'
block 'az role assignment list --assignee "$REPORTER_PID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table'
block 'az role assignment list --assignee "$REMEDIATION_PID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table'
block 'az role assignment list --assignee "$CI_SP_ID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table'
block 'az cosmosdb sql role assignment list --account-name "$COSMOS_NAME" --resource-group rg-grc-evidence-dev --query "[].{principal:principalId, role:roleDefinitionId}" -o table'

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
echo "  Deny refusals, expect at least 1: $(grep -c 'RequestDisallowedByPolicy' "$OUT")"
echo "  $(grep -E '^[0-9]+ of [0-9]+ reports reproduce' "$OUT" || echo 'Report trace: no reports found')"
echo "Read it before you commit it."
