# Azure GRC Evidence Pipeline

My capstone for **CGE-AZ: Certified GRC Engineer, Azure Specialty** from the GRC
Engineering Club. It started as the course's starter repo; the fixes and additions I
made are listed under [What I changed](#what-i-changed-from-the-course-starter).

The pipeline runs in my own Azure subscription and turns Azure's own security
signals into audit evidence:

1. **Detect.** Defender for Cloud assesses the subscription, and a six-policy Azure
   Policy initiative, assigned at the management group, checks every resource
   against my baseline.
2. **Record.** Every night a collector Function copies every Defender assessment
   into a Cosmos DB database I own, stamped with the run that collected it.
3. **Report.** A reporter Function builds a POA&M every day and a SAR every week
   from that database only. It writes them to a storage container where they can't
   be changed or deleted for 90 days.
4. **Repair.** Azure Policy fixes what it can. Repairs to existing resources run as
   a dedicated remediation identity, after a human approves them.
5. **Watch.** Every pull request has to pass a compliance gate (a Terraform plan
   checked against OPA rules) before it can merge, and a nightly drift check opens
   an issue when Azure no longer matches the code.

How the pieces fit, who can do what, and why:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Every policy, collector and gate rule,
mapped to NIST CSF 2.0: [docs/CONTROLS.md](docs/CONTROLS.md).

## Repository layout

| Path | What's there |
|---|---|
| `stages/` | Terraform root modules, one per pipeline stage, each with its own state |
| `functions/` | Python Function code: the collector and the report generators |
| `policy/` | The OPA rules the compliance gate applies to every Terraform plan |
| `.github/workflows/` | `compliance-gate` (every pull request) and `drift-detection` (nightly) |
| `labs/` | The course's lab guides, plus the helper scripts the deploy steps below use |
| `docs/` | Architecture, control mappings, and the course's setup guide and rubric |

## Deploy from an empty subscription

You need an Azure subscription where you are Owner, in a tenant that lets you create
management groups and app registrations, and your own fork of this repo. Tools: the
Azure CLI, Terraform 1.9 or newer, Python 3.11 or newer, git, `zip`, and the GitHub
CLI signed in with `gh auth login`. Run every step in a Linux shell (WSL works) from
the root of your clone. [docs/SETUP.md](docs/SETUP.md) covers installs, regional
quirks and Windows notes.

Coming from the course labs, where Labs 1 and 2 built some of this by hand? Import
those resources instead of recreating them: step 2 of
[Lab 3](labs/03-foundation/README.md) and step 1 of
[Lab 4](labs/04-evidence/README.md) have the commands.

### 0. Sign in and set the variables every step uses

```bash
az login
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export TF_VAR_owner_email="you@example.com"   # owner tag on every governed resource group
GH_OWNER="your-github-user"
GH_REPO="$GH_OWNER/cgeaz"
CGEAZ=$(pwd)

for ns in Microsoft.Management Microsoft.OperationalInsights Microsoft.Security \
          Microsoft.DocumentDB Microsoft.Web Microsoft.Storage Microsoft.Insights \
          Microsoft.PolicyInsights; do
  az provider register --namespace "$ns" --wait
done

./labs/00-setup/probe-quota.sh
```

Free accounts have no Function (Y1) quota in most US regions. If the probe doesn't
mark `centralus` as OK, choose a region it does mark, for example
`export TF_VAR_functions_location=westus3`.

### 1. Cost guardrail

```bash
./labs/01-sandbox/create-budget.sh "$TF_VAR_owner_email"
```

A $10-a-month budget that emails you at 80% of actual spend and 100% of forecast.

### 2. Remote state

```bash
./labs/03-foundation/bootstrap.sh
export TF_VAR_state_storage_account=$(grep storage_account_name labs/03-foundation/backend.hcl | cut -d'"' -f2)
```

Creates `rg-grc-tfstate` with a versioned storage account for Terraform state,
grants you blob data access to it, and writes `labs/03-foundation/backend.hcl`,
which every stage's `terraform init` reads. If the next `init` fails with a 403, the
new role is still propagating: wait a few minutes and run it again.

### 3. Foundation (stage 01)

```bash
cd "$CGEAZ/stages/01-foundation"
terraform init -backend-config="$CGEAZ/labs/03-foundation/backend.hcl"
terraform apply
cd "$CGEAZ"
```

Creates the `mg-grc` -> `mg-grc-sandbox` management groups and moves the
subscription under them, plus the sandbox and evidence resource groups, the Log
Analytics workspace, the remediation identity and the six-policy initiative. The
first management group in a new tenant can take a few minutes. If the apply fails
with `PrincipalNotFound`, the new identity hasn't replicated yet: run
`terraform apply` again.

### 4. Activity Log routing

```bash
./labs/02-toolkit/route-activity-log.sh
```

Sends the subscription's Activity Log to `law-grc-sandbox`, so every change can be
traced to whoever made it. On a new workspace the first rows can take 30 to 60
minutes to appear.

### 5. Defender plans and NIST CSF 2.0 (stage 02)

```bash
cd "$CGEAZ/stages/02-activation"
terraform init -backend-config="$CGEAZ/labs/03-foundation/backend.hcl"
terraform apply
terraform output
cd "$CGEAZ"
```

Stage 02 reads each Defender plan's current tier before changing anything, and
`activation_needed` in the output shows the gap the apply closed. Turning the plans
on starts their 30-day free trials. On a new subscription, Defender's first
assessments can take up to a day to appear.

### 6. Evidence store and collector (stage 03)

```bash
cd "$CGEAZ/stages/03-evidence-store"
terraform init -backend-config="$CGEAZ/labs/03-foundation/backend.hcl"
terraform apply

cd "$CGEAZ/functions/collect_assessments"
rm -f /tmp/collector.zip
zip -r /tmp/collector.zip .
az functionapp deployment source config-zip \
  --name "$(cd "$CGEAZ/stages/03-evidence-store" && terraform output -raw collector_function_app)" \
  --resource-group rg-grc-evidence-dev --src /tmp/collector.zip --build-remote true --timeout 600

cd "$CGEAZ/labs/04-evidence"
python3 -m venv ~/cge-venv
. ~/cge-venv/bin/activate
pip install azure-cosmos azure-identity
COSMOS_ENDPOINT=$(cd "$CGEAZ/stages/03-evidence-store" && terraform output -raw cosmos_endpoint) python3 seed_frameworks.py
cd "$CGEAZ"
```

The apply builds Cosmos DB with key-based access off, the evidence storage account
with shared keys off and a 90-day WORM policy on its `reports` container, the
collector Function App, and the role grants for the collector and for you. Cosmos
alone can take several minutes. It defaults to `eastus2` because East US often has
no Cosmos capacity for new subscriptions; if it fails with `ServiceUnavailable`,
set `TF_VAR_location` to another region and apply again. The code deploy builds the
Python dependencies in Azure, so it holds the terminal for a few minutes. The seed
script loads seven NIST CSF 2.0 documents into the `frameworks` container. If it
fails with an authorization error, your new Cosmos role is still propagating.

### 7. Reporting (stage 04)

```bash
cd "$CGEAZ/stages/04-reporting"
terraform init -backend-config="$CGEAZ/labs/03-foundation/backend.hcl"
terraform apply

cd "$CGEAZ/functions/reports"
rm -f /tmp/reports.zip
zip -r /tmp/reports.zip .
az functionapp deployment source config-zip \
  --name "$(cd "$CGEAZ/stages/04-reporting" && terraform output -raw reporting_function_app)" \
  --resource-group rg-grc-evidence-dev --src /tmp/reports.zip --build-remote true --timeout 600
cd "$CGEAZ"
```

The reporter can read Cosmos and write report files, and nothing else.

### 8. Enforcement (stage 06)

```bash
cd "$CGEAZ/stages/06-enforcement"
terraform init -backend-config="$CGEAZ/labs/03-foundation/backend.hcl"
terraform apply
cd "$CGEAZ"
```

Deploys the public-blob-access repair policy in dry-run mode: Azure reports what it
would fix, and a human starts each fix by creating a remediation task. Switching to
automatic repair is a reviewed pull request that changes `remediation_mode` to
`enforce`.

### 9. Arm CI on your fork

Run this for your own fork only, never for the upstream course repo; the script's
header explains why. It creates the app registration that GitHub Actions signs in as
through OIDC, with no secret, and grants it the roles its plans need.

```bash
./labs/06-loop/arm-your-fork.sh "$GH_OWNER"
```

GitHub's OIDC tokens for my fork carry the owner's and repo's numeric IDs, so the
name-based trust rules the script creates never matched and sign-in failed with
`AADSTS700213`. If yours do the same, replace the script's rules with ID-based ones:

```bash
APP_ID=$(az ad app list --display-name "github-cgeaz-$GH_OWNER" --query "[0].appId" -o tsv)
APP_OBJ=$(az ad app show --id "$APP_ID" --query id -o tsv)
SUBJ="repo:$GH_OWNER@$(gh api "repos/$GH_REPO" --jq .owner.id)/cgeaz@$(gh api "repos/$GH_REPO" --jq .id)"
az ad app federated-credential create --id "$APP_OBJ" --parameters "{\"name\":\"cgeaz-main-id\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$SUBJ:ref:refs/heads/main\",\"audiences\":[\"api://AzureADTokenExchange\"]}"
az ad app federated-credential create --id "$APP_OBJ" --parameters "{\"name\":\"cgeaz-pr-id\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$SUBJ:pull_request\",\"audiences\":[\"api://AzureADTokenExchange\"]}"
az ad app federated-credential delete --id "$APP_OBJ" --federated-credential-id cgeaz-main
az ad app federated-credential delete --id "$APP_OBJ" --federated-credential-id cgeaz-pr
```

Then give the workflows what they need, switch them on, and protect `main`:

```bash
APP_ID=$(az ad app list --display-name "github-cgeaz-$GH_OWNER" --query "[0].appId" -o tsv)
gh variable set AZURE_CLIENT_ID --body "$APP_ID" --repo "$GH_REPO"
gh variable set AZURE_TENANT_ID --body "$(az account show --query tenantId -o tsv)" --repo "$GH_REPO"
gh variable set AZURE_SUBSCRIPTION_ID --body "$ARM_SUBSCRIPTION_ID" --repo "$GH_REPO"
gh variable set STATE_STORAGE_ACCOUNT --body "$TF_VAR_state_storage_account" --repo "$GH_REPO"
gh variable set OWNER_EMAIL --body "$TF_VAR_owner_email" --repo "$GH_REPO"
gh variable set DEPLOYER_OBJECT_ID --body "$(az ad signed-in-user show --query id -o tsv)" --repo "$GH_REPO"
gh api -X PUT "repos/$GH_REPO/actions/workflows/gate.yml/enable"
gh api -X PUT "repos/$GH_REPO/actions/workflows/drift.yml/enable"
gh api -X PUT "repos/$GH_REPO/branches/main/protection" --input - <<'EOT'
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["gate (01-foundation)", "gate (03-evidence-store)", "gate (04-reporting)", "gate (06-enforcement)"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null
}
EOT
```

These are repository variables, not secrets: with OIDC there's no credential to
protect, only identifiers. `DEPLOYER_OBJECT_ID` names you as the deployer in CI's
plans, so they match the plans you run. Forks start with their workflows switched
off, which is why the two `enable` calls are there. Branch protection makes all four
gate checks required on `main`, for admins too. To prove the gate works, open a pull
request that adds a public storage account: the gate must fail it. Mine is
[PR #1](https://github.com/gregorywilsonjr/cgeaz/pull/1), closed unmerged.

### 10. Optional: the course's auditor group and demo account

```bash
az ad group create --display-name grc-auditors --mail-nickname grc-auditors
az role assignment create --assignee-object-id "$(az ad group show --group grc-auditors --query id -o tsv)" \
  --assignee-principal-type Group --role Reader \
  --scope "$(az group show --name rg-grc-sandbox-dev --query id -o tsv)"
az storage account create --name "stgrcseed$RANDOM" --resource-group rg-grc-sandbox-dev \
  --location eastus --sku Standard_LRS --min-tls-version TLS1_2 --tags env=dev purpose=cge-az-labs
```

`grc-auditors` gets read-only access to the sandbox resource group and nothing else.
The seed storage account gives Defender something to assess and gives the repair
loop in [Lab 6](labs/06-loop/README.md) something to break and fix. It sets TLS 1.2
explicitly, so it passes my `cge-storage-min-tls12` control.

### First results

The timers take over from here; the schedule is in
[ARCHITECTURE.md](docs/ARCHITECTURE.md#schedules). To run a collection now instead
of waiting for 05:00 UTC:

```bash
APP=$(cd "$CGEAZ/stages/03-evidence-store" && terraform output -raw collector_function_app)
KEY=$(az functionapp function keys list --name "$APP" --resource-group rg-grc-evidence-dev --function-name collect_now --query default -o tsv)
curl "https://$APP.azurewebsites.net/api/collect?code=$KEY"
```

It prints the run ID, the number of documents written and the time. `0 documents`
is a clean run if Defender hasn't finished its first cycle. The key in that URL is a
secret, so don't paste the URL anywhere.

## Operating it

- **Changing anything:** branch, pull request, gate, merge, then `terraform apply`
  for that stage from your machine. CI plans but never applies. A change made
  outside the repo to anything stages 01, 03, 04 or 06 manage shows up in the next
  night's drift issue.
- **Escalating a control:** each Audit or Deny policy's effect, and stage 06's
  remediation mode, is a Terraform variable. New controls start at Audit, and
  moving one to Deny or to enforce is a one-line, reviewed pull request.
- **Reading reports:** list the files, then download one with
  `az storage blob download`:

```bash
STG=$(cd "$CGEAZ/stages/03-evidence-store" && terraform output -raw evidence_storage_account)
az storage blob list --account-name "$STG" --container-name reports --auth-mode login --query "[].name" -o tsv
```

## Proof points

| Claim | Where to see it |
|---|---|
| The gate blocks a non-compliant plan | [PR #1](https://github.com/gregorywilsonjr/cgeaz/pull/1): a public, shared-key storage account that `storage.rego` failed, closed unmerged |
| Reports can't be changed or deleted | Deleting a report fails with `BlobImmutableDueToPolicy`, even for an Owner ([Lab 4](labs/04-evidence/README.md), step 7) |
| A human approves each repair, and the repair runs as the remediation identity | The Activity Log shows the principal ID of `id-grc-remediation-dev` as the caller on the seed account's fix ([Lab 6](labs/06-loop/README.md), step 4) |
| Drift detection runs every night | The `drift-detection` run history in this repo's Actions tab |
| Run history builds up over time | Dated POA&M and SAR files in the `reports` container |
| Controls of my own | Three policies, mapped to NIST CSF 2.0, in [CONTROLS.md](docs/CONTROLS.md) |

## What I changed from the course starter

Fixes, each one found by running the pipeline for real:

- **Findings had no severity.** Defender's assessment list call doesn't return
  severity, so every finding came out "Unknown" and every POA&M item got the default
  90-day due date. The collector now looks up each finding's severity in Defender's
  metadata catalog ([collector](functions/collect_assessments/function_app.py)).
- **CI couldn't run.** The workflows read `backend.hcl`, which is gitignored, so
  `terraform init` failed. They now pass the backend settings inline, with the state
  account's name from a repository variable. The gate's conftest action was a 2020
  image that can't parse current Rego (`import rego.v1`), so the gate now downloads
  a pinned conftest release and checks its SHA-256 before running it
  ([gate.yml](.github/workflows/gate.yml)).
- **Drift detection could never fire.** The `setup-terraform` wrapper reports
  Terraform's exit code 2 ("changes found") as 0, so a drifted stage looked clean.
  The wrapper is off in both workflows ([drift.yml](.github/workflows/drift.yml)).
- **Two stages always showed drift.** The code deploy command deletes the
  `ENABLE_ORYX_BUILD` app setting, so declaring it in Terraform guaranteed a diff.
  Stages 03 and 04 no longer declare it.
- **CI's plans tried to move my data roles.** Stage 03 granted data access to
  "whoever runs Terraform," so CI's plans proposed moving those grants to the CI
  identity. The deployer is now named explicitly (`deployer_object_id`, which CI
  sets from `DEPLOYER_OBJECT_ID`).
- **CI couldn't sign in.** GitHub's OIDC tokens for my fork carry numeric owner and
  repo IDs, so the setup script's name-based trust rules never matched. The fork
  now trusts ID-based subjects, which is also safer: someone else can register a
  name after it's freed, but an ID is never reused.
- **One failing stage hid the others.** The gate cancelled the remaining stages
  when one failed. With `fail-fast` off, every stage reports its own verdict.

Additions:

- **Three controls of my own,** each added at Audit through a pull request that
  passed the gate: Cosmos DB must disable key-based access
  ([PR #2](https://github.com/gregorywilsonjr/cgeaz/pull/2)), resource groups must
  name an owner ([PR #3](https://github.com/gregorywilsonjr/cgeaz/pull/3)), and
  storage must require TLS 1.2 or newer
  ([PR #5](https://github.com/gregorywilsonjr/cgeaz/pull/5)). The reasoning is in
  [CONTROLS.md](docs/CONTROLS.md).
- **A fix at the source for my own finding.** The owner-tag control flagged the
  state resource group, so [`bootstrap.sh`](labs/03-foundation/bootstrap.sh) now
  tags it with an owner ([PR #4](https://github.com/gregorywilsonjr/cgeaz/pull/4)).
- **Branch protection** that requires all four gate checks, for admins too.
- **This README and [ARCHITECTURE.md](docs/ARCHITECTURE.md),** which covers the
  stage flow, identity boundaries, design decisions and known gaps.

Known gaps are tracked, each with its fix, in
[ARCHITECTURE.md](docs/ARCHITECTURE.md#known-gaps-and-trade-offs).

## Teardown

Only after the capstone is graded, because the grader reads run history from the
evidence store. Use the same shell variables as the deploy steps. Delete the
hand-made seed account first, since Terraform won't delete a resource group that
still holds resources it doesn't manage. Then destroy the stages in reverse order
and delete the CI app registration:

```bash
SEED=$(az storage account list --resource-group rg-grc-sandbox-dev --query "[?starts_with(name,'stgrcseed')].name" -o tsv)
az storage account delete --name "$SEED" --resource-group rg-grc-sandbox-dev --yes
for stage in 06-enforcement 04-reporting 03-evidence-store 02-activation 01-foundation; do
  (cd "$CGEAZ/stages/$stage" && terraform destroy)
done
az ad app delete --id "$(az ad app list --display-name "github-cgeaz-$GH_OWNER" --query "[0].appId" -o tsv)"
```

Destroying stage 02 turns the Defender plans back to Free. The budget, the
Activity Log routing, the auditor group and `rg-grc-tfstate` were made by script or
by hand, so remove them the same way if you want an empty subscription again.

## Credits

Built on the [CGE-AZ pipeline starter](https://github.com/GRCEngClub/cgeaz) from the
GRC Engineering Club. The lab guides in `labs/`, and the setup guides, rubric and
validation log in `docs/`, are theirs.
