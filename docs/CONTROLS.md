# Control Mappings

Every policy, collector, report generator and gate rule in this repo, mapped to the
NIST CSF 2.0 category it serves. "Effect today" is what is in force right now. Every
Audit or Deny effect, and stage 06's remediation mode, is a Terraform variable, so
changing one is a reviewed, one-line pull request.
Live proof for anything on this page is in [EVIDENCE.md](EVIDENCE.md), and the reasons
behind the design are in [ARCHITECTURE.md](ARCHITECTURE.md).

## Azure Policy controls

The six stage 01 policies are one initiative, `cge-grc-baseline`, assigned once at
`mg-grc-sandbox`, so every subscription under it inherits them. Stage 06's repair
policy has its own assignment at the same scope.

| Control | Effect today | What it enforces | Code | CSF 2.0 |
|---|---|---|---|---|
| Management group hierarchy and initiative assignment | n/a | One assignment governs every current and future subscription under `mg-grc-sandbox` | [main.tf](../stages/01-foundation/main.tf), [policies.tf](../stages/01-foundation/policies.tf) | GV.PO, PR.PS |
| `cge-require-env-tag-rg` | Audit | Every resource group declares its environment with an `env` tag | [policies.tf](../stages/01-foundation/policies.tf) | ID.AM |
| `cge-deny-public-blob` | Deny | No storage account can allow public blob access, on create or on update | [policies.tf](../stages/01-foundation/policies.tf) | PR.DS |
| `cge-dine-storage-diagnostics` | DeployIfNotExists | Every storage account sends its metrics to `law-grc-sandbox`; a missing diagnostic setting is added | [policies.tf](../stages/01-foundation/policies.tf) | PR.PS, DE.CM |
| `cge-cosmos-disable-local-auth` *(mine)* | Audit | No Cosmos DB account accepts account keys, so every evidence write is made by a named identity | [policies.tf](../stages/01-foundation/policies.tf) | PR.AA, PR.DS |
| `cge-require-owner-tag-rg` *(mine)* | Audit | Every resource group names an accountable owner in a non-empty `owner` tag | [policies.tf](../stages/01-foundation/policies.tf) | GV.RR, ID.AM |
| `cge-storage-min-tls12` *(mine)* | Audit | Every storage account declares a minimum TLS version of 1.2 or newer | [policies.tf](../stages/01-foundation/policies.tf) | PR.DS |
| `cge-fix-public-blob` (stage 06) | Modify, dry-run | Turns public blob access off on existing accounts, but only when a person starts a remediation task | [main.tf](../stages/06-enforcement/main.tf) | PR.DS, RS.MI |
| `remediation_mode` variable (stage 06) | `dry-run` | Moving from audit to dry-run to enforce is a reviewed change: automation acts, a human authorizes | [variables.tf](../stages/06-enforcement/variables.tf) | GV.PO, GV.RR |
| Remediation identity `id-grc-remediation-dev` | n/a | Every automated fix runs as one named identity with a whitelist of roles, so the Activity Log shows its author | [identity.tf](../stages/01-foundation/identity.tf) | PR.AA, GV.RR |

### Blast radius and rollback

What each policy can touch if it acts, and how to back it out. The same notes sit in
the code next to each policy.

- **`cge-deny-public-blob` (Deny):** refuses any create or update that would leave a
  storage account under `mg-grc-sandbox` open to public blob access, including my own
  Terraform and CLI changes. It changes nothing that already exists. Rollback: set
  `public_blob_policy_effect` to `Audit` in a reviewed PR (Lab 6 did exactly that, then
  set it back).
- **`cge-dine-storage-diagnostics` (DeployIfNotExists):** creates one diagnostic setting
  per storage account, as the remediation identity. It never modifies or deletes
  anything else. Rollback: remove it from the initiative in a reviewed PR; settings it
  already created stay until deleted.
- **`cge-fix-public-blob` (Modify, dry-run):** sets `allowBlobPublicAccess` to `false`
  on existing storage accounts, and only after a person creates a remediation task. It
  can't delete anything, read data or touch any other property. Rollback: set
  `remediation_mode` back to `audit`.
- **The four Audit policies** only flag; they change nothing. At Deny:
  - `cge-require-env-tag-rg` and `cge-require-owner-tag-rg` would block creating or
    updating a resource group without the tag, including the temporary group that the
    course's `probe-quota.sh` creates.
  - `cge-cosmos-disable-local-auth` would block any Cosmos DB account that accepts keys.
  - `cge-storage-min-tls12` would block any storage account that doesn't declare TLS 1.2
    or newer.
  - Rollback for each: its `*_policy_effect` variable back to `Audit` in a reviewed PR.

## Evidence plane: collection and reporting

| Component | What it does | Code | CSF 2.0 |
|---|---|---|---|
| Defender plans (Storage, Key Vault) | Threat detection and assessments at Standard; stage 02 reads each plan's tier before changing anything | [main.tf](../stages/02-activation/main.tf) | DE.CM, ID.RA |
| NIST CSF 2.0 regulatory standard | Defender scores the subscription against CSF 2.0 | [main.tf](../stages/02-activation/main.tf) | GV.OV, ID.RA |
| Collector Function (daily, 05:00 UTC) | Copies every Defender assessment into Cosmos with its severity, `runId` and `collectedAt`. Every run is kept, so any report can be re-checked against the run it was built from. It can read the platform but not change it | [function_app.py](../functions/collect_assessments/function_app.py), [collector.tf](../stages/03-evidence-store/collector.tf) | DE.CM, ID.RA |
| Evidence database (`assessments`, `frameworks`, `mappings`) | An evidence schema I own, so reports don't depend on a vendor's view staying the same | [main.tf](../stages/03-evidence-store/main.tf) | GV.OV, ID.RA |
| Identity-only access to the evidence | Cosmos local auth off, shared keys off on the evidence storage, data-plane RBAC for every reader and writer | [main.tf](../stages/03-evidence-store/main.tf) | PR.AA |
| WORM `reports` container | Time-based retention: no report can be changed or deleted by anyone for 90 days after it's written | [main.tf](../stages/03-evidence-store/main.tf) | PR.DS |
| POA&M generator (daily, 06:00 UTC) | Every open finding from the newest run, with a due date by severity: High 30 days, Medium 90, Low 180 | [function_app.py](../functions/reports/function_app.py) | ID.IM, GV.RM |
| SAR generator (weekly, Monday 07:00 UTC) | Findings by severity, each one traceable to its stored document | [function_app.py](../functions/reports/function_app.py) | ID.RA, GV.OV |
| Collector and reporter as separate identities | The identity that records facts can't write reports, and the one that writes reports can't touch the facts or the platform | [collector.tf](../stages/03-evidence-store/collector.tf), [main.tf](../stages/04-reporting/main.tf) | PR.AA, GV.RR |
| Activity Log to `law-grc-sandbox` | Makes every change queryable by who made it; the workspace keeps 30 days | [route-activity-log.sh](../labs/02-toolkit/route-activity-log.sh) | DE.CM, PR.PS |

## Pipeline controls: the repo's own guardrails

| Control | What it prevents or catches | Code | CSF 2.0 |
|---|---|---|---|
| `compliance-gate` workflow and branch protection | Nothing merges to `main` until stages 01, 03, 04 and 06 plan cleanly and pass every rule below; admins included | [gate.yml](../.github/workflows/gate.yml) | PR.PS, GV.PO |
| `storage.rego` | A Terraform storage account that allows public blob access, or shared keys outside the Function runtime exception | [storage.rego](../policy/storage.rego) | PR.DS |
| `policy_identity.rego` | A policy assignment without an identity, whose remediation would silently never run | [policy_identity.rego](../policy/policy_identity.rego) | PR.PS |
| `broad_roles.rego` | An Owner or Contributor role assignment in Terraform | [broad_roles.rego](../policy/broad_roles.rego) | PR.AA |
| `drift-detection` workflow (nightly, 08:00 UTC) | Azure no longer matching the code; a drifted stage opens a GitHub issue labeled `drift` | [drift.yml](../.github/workflows/drift.yml) | DE.CM |
| "Who is touching Azure" Activity Log query | Changes by anyone, human or identity, counted by caller | [EVIDENCE.md](EVIDENCE.md#7-drift-detection-in-both-directions) | DE.CM, DE.AE |
| Evidence script | Regenerates the proof page from live output and refuses to publish personal identifiers | [capture-evidence.sh](../scripts/capture-evidence.sh) | GV.OV |

## My three controls

Each one started at Audit, was merged through the gate, and has a record of what it
found and how that was closed.

### Cosmos DB must disable key-based access (`cge-cosmos-disable-local-auth`)

- **Why:** evidence is only trustworthy if every write is made by a named identity.
  An account key is a shared secret that lets whoever holds it write evidence with no
  identity attached. Stage 03 already turns keys off; this control makes sure a new or
  changed account can't quietly turn them back on.
- **Design:** it follows Microsoft's built-in version of this policy, including its
  exclusion of MongoDB, Cassandra and Gremlin API accounts.
- **Found:** nothing. The evidence database was keyless from the first scan, so this
  control guards against a regression rather than fixing one.

### Resource groups must name an owner (`cge-require-owner-tag-rg`)

- **Why:** a finding without an owner doesn't get fixed. Every resource group has to
  name who is accountable for what's in it, and the POA&M's owner column is meant to
  come from this tag.
- **Design:** a tag that exists but is empty fails too, because it names no one.
- **Found:** `rg-grc-tfstate`. The course's `bootstrap.sh` created the state resource
  group without an owner tag. I fixed it at the source, so the script now sets the tag
  ([PR #4](https://github.com/gregorywilsonjr/cgeaz/pull/4)), re-ran it, and the next
  scan showed the group Compliant.

### Storage must require TLS 1.2 or newer (`cge-storage-min-tls12`)

- **Why:** evidence, reports and Terraform state all travel to storage accounts. Since
  February 3, 2026, Azure Storage refuses TLS 1.0 and 1.1 on every account, so the real
  exposure is low. What this control checks is each account's declared minimum:
  configuration an auditor can verify, rather than a platform default.
- **Design:** Microsoft's built-in version flags anything that isn't exactly TLS 1.2,
  which would wrongly flag a stricter TLS 1.3 minimum. Mine flags only versions below
  1.2, or no minimum at all.
- **Found:** the seed storage account, created by hand in Lab 2 without a TLS setting,
  declared a TLS 1.0 minimum. I rated it low severity because of the platform floor and
  fixed it anyway with a recorded CLI change (the account is outside Terraform on
  purpose). The next scan showed it Compliant, and the Activity Log shows who made the
  change.

### Findings log

| Control | Finding | Severity | Fix | Confirmed |
|---|---|---|---|---|
| `cge-require-owner-tag-rg` | `rg-grc-tfstate` had no `owner` tag | Low | `bootstrap.sh` tags the group ([PR #4](https://github.com/gregorywilsonjr/cgeaz/pull/4)) | Compliant, 2026-09-20 ([evidence](EVIDENCE.md#8-policy-compliance-right-now)) |
| `cge-storage-min-tls12` | Seed storage account declared TLS 1.0 | Low | `az storage account update --min-tls-version TLS1_2`, recorded in the Activity Log | Compliant, 2026-09-20 ([evidence](EVIDENCE.md#8-policy-compliance-right-now)) |
| `cge-cosmos-disable-local-auth` | None | n/a | n/a | Compliant since the first scan |

## Limitations

Control-level gaps I know about. Pipeline-level ones are in
[ARCHITECTURE.md](ARCHITECTURE.md#known-gaps-and-trade-offs).

- **The crosswalk isn't built yet.** The `mappings` container is empty, so findings
  aren't yet mapped to CSF 2.0 categories as data. The course left this for its
  optional Stage 5.
- **Some findings have no severity.** For some assessments (12 of 33 open findings in
  the 2026-09-20 run), the collector found no severity in Defender's metadata catalog
  or on the assessment itself. They show as Unknown and get the POA&M's default 90-day
  due date.
- **The POA&M owner column is a placeholder.** Every resource group's `owner` tag is
  checked, but the generator doesn't read it yet.
