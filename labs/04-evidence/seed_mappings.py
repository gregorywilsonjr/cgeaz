#!/usr/bin/env python3
"""The NIST CSF 2.0 crosswalk, kept as data in the evidence store.

Every control in docs/CONTROLS.md is one row in the `mappings` container: the CSF 2.0
categories it serves and the file that implements it. CONTROLS.md is the readable version
of this table, so the two have to agree. This script refuses to seed when they don't,
guide-ci runs the same check on every pull request that touches the docs, and the evidence
page reads the rows back out of the store.

    python3 seed_mappings.py --check    # compare with CONTROLS.md and the repo; writes nothing
    python3 seed_mappings.py            # the same check, then upsert every row
    python3 seed_mappings.py --report   # coverage read back from the store, and the checks

Row IDs are a hash of the framework, source type and source ID, so a re-run updates the
same rows instead of adding more, and a row whose control has left the table is removed.
Seeding and --report need COSMOS_ENDPOINT (a stage 03 output) and run as you: the
evidence database has key-based access off, and stage 03 grants the deployer its
data-plane role.
"""

import collections
import hashlib
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from seed_frameworks import CSF2_FUNCTIONS  # noqa: E402  (one category catalog, not two)

FRAMEWORK_ID = "nist-csf-2.0"
CATEGORIES = [c for _, cats in CSF2_FUNCTIONS.values() for c in cats]

# (sourceType, sourceId, CSF 2.0 categories, code path), in CONTROLS.md order.
# The categories are the ones CONTROLS.md gives each control: change both in one PR.
CROSSWALK = [
    # Azure Policy controls
    ("governance", "mg-grc-sandbox-initiative-assignment", ["GV.PO", "PR.PS"], "stages/01-foundation/policies.tf"),
    ("azure-policy", "cge-require-env-tag-rg", ["ID.AM"], "stages/01-foundation/policies.tf"),
    ("azure-policy", "cge-deny-public-blob", ["PR.DS"], "stages/01-foundation/policies.tf"),
    ("azure-policy", "cge-dine-storage-diagnostics", ["PR.PS", "DE.CM"], "stages/01-foundation/policies.tf"),
    ("azure-policy", "cge-cosmos-disable-local-auth", ["PR.AA", "PR.DS"], "stages/01-foundation/policies.tf"),
    ("azure-policy", "cge-require-owner-tag-rg", ["GV.RR", "ID.AM"], "stages/01-foundation/policies.tf"),
    ("azure-policy", "cge-storage-min-tls12", ["PR.DS"], "stages/01-foundation/policies.tf"),
    ("azure-policy", "cge-fix-public-blob", ["PR.DS", "RS.MI"], "stages/06-enforcement/main.tf"),
    ("control", "remediation-mode", ["GV.PO", "GV.RR"], "stages/06-enforcement/variables.tf"),
    ("identity", "id-grc-remediation-dev", ["PR.AA", "GV.RR"], "stages/01-foundation/identity.tf"),
    # Evidence plane: collection and reporting
    ("defender", "defender-plans-storage-keyvault", ["DE.CM", "ID.RA"], "stages/02-activation/main.tf"),
    ("framework", "nist-csf-20-standard", ["GV.OV", "ID.RA"], "stages/02-activation/main.tf"),
    ("collector", "collect-assessments", ["DE.CM", "ID.RA"], "functions/collect_assessments/function_app.py"),
    ("evidence-store", "grc-evidence-database", ["GV.OV", "ID.RA"], "stages/03-evidence-store/main.tf"),
    ("evidence-store", "identity-only-evidence-access", ["PR.AA"], "stages/03-evidence-store/main.tf"),
    ("evidence-store", "worm-reports-container", ["PR.DS"], "stages/03-evidence-store/main.tf"),
    ("report", "generate-poam", ["ID.IM", "GV.RM"], "functions/reports/function_app.py"),
    ("report", "generate-sar", ["ID.RA", "GV.OV"], "functions/reports/function_app.py"),
    ("identity", "collector-reporter-separation", ["PR.AA", "GV.RR"], "stages/03-evidence-store/collector.tf"),
    ("detector", "activity-log-to-workspace", ["DE.CM", "PR.PS"], "stages/01-foundation/monitoring.tf"),
    # Pipeline controls: the repo's own guardrails
    ("gate", "compliance-gate-branch-protection", ["PR.PS", "GV.PO"], ".github/workflows/gate.yml"),
    ("gate", "tier0-static-checks", ["PR.PS"], ".github/workflows/gate.yml"),
    ("gate-rule", "storage-rego", ["PR.DS"], "policy/storage.rego"),
    ("state", "terraform-state-storage", ["PR.AA", "PR.DS"], "labs/03-foundation/bootstrap.sh"),
    ("gate-rule", "policy-identity-rego", ["PR.PS"], "policy/policy_identity.rego"),
    ("gate-rule", "broad-roles-rego", ["PR.AA"], "policy/broad_roles.rego"),
    ("detector", "terraform-drift", ["DE.CM"], ".github/workflows/drift.yml"),
    ("detector", "control-plane-change-alert", ["DE.CM", "DE.AE"], "stages/01-foundation/monitoring.tf"),
    ("evidence", "capture-evidence", ["GV.OV"], "scripts/capture-evidence.sh"),
    ("evidence", "csf-crosswalk", ["GV.OV"], "labs/04-evidence/seed_mappings.py"),
]


def mapping_id(source_type, source_id):
    """Stable across runs, so a re-run updates the same row instead of adding one."""
    raw = f"{FRAMEWORK_ID}|{source_type}|{source_id}".encode()
    return "map-" + hashlib.sha256(raw).hexdigest()[:24]


def controls_md(path=REPO_ROOT / "docs" / "CONTROLS.md"):
    """Count the controls and categories in every CONTROLS.md table whose last column is CSF 2.0."""
    rows, counts, in_table = 0, collections.Counter(), False
    for line in path.read_text().splitlines():
        if not line.startswith("|"):
            in_table = False
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if cells[-1] == "CSF 2.0":
            in_table = True
        elif in_table and cells[-1].strip("-: "):
            rows += 1
            counts.update(c.strip() for c in cells[-1].split(",") if c.strip())
    return rows, counts


def problems(entries, where, catalog):
    """Everything that would make these rows untrue. An empty list means they can stand."""
    found = []
    keys = collections.Counter((t, s) for t, s, _, _ in entries)
    found += [f"{t}/{s} appears {n} times" for (t, s), n in sorted(keys.items()) if n > 1]
    for _, source_id, categories, code_path in entries:
        found += [f"{source_id}: {c} is not a NIST CSF 2.0 category" for c in categories if c not in catalog]
        if not (REPO_ROOT / code_path).is_file():
            found.append(f"{source_id}: {code_path} does not exist in this repo")
    doc_rows, doc_counts = controls_md()
    counts = collections.Counter(c for _, _, cats, _ in entries for c in cats)
    if doc_rows != len(entries):
        found.append(f"CONTROLS.md lists {doc_rows} controls; {where} has {len(entries)}")
    for c in sorted(set(doc_counts) | set(counts)):
        if doc_counts[c] != counts[c]:
            found.append(f"{c}: {doc_counts[c]} in CONTROLS.md, {counts[c]} in {where}")
    return found


def database():
    from azure.cosmos import CosmosClient
    from azure.identity import DefaultAzureCredential

    return CosmosClient(os.environ["COSMOS_ENDPOINT"], DefaultAzureCredential()).get_database_client(
        os.environ.get("COSMOS_DATABASE", "grc"))


def seed():
    container = database().get_container_client("mappings")
    wanted = set()
    for source_type, source_id, categories, code_path in CROSSWALK:
        wanted.add(mapping_id(source_type, source_id))
        container.upsert_item({
            "id": mapping_id(source_type, source_id),
            "frameworkId": FRAMEWORK_ID,
            "sourceType": source_type,
            "sourceId": source_id,
            "targetType": "category",
            "targetIds": categories,
            "codePath": code_path,
            "schemaVersion": 1,
        })
    # A control renamed or removed here leaves its old row behind; the store must equal the table.
    stale = [r["id"] for r in container.query_items(f"SELECT c.id FROM c WHERE c.frameworkId = '{FRAMEWORK_ID}'",
                                                     enable_cross_partition_query=True) if r["id"] not in wanted]
    for doc_id in stale:
        container.delete_item(item=doc_id, partition_key=FRAMEWORK_ID)
    print(f"seeded {len(CROSSWALK)} rows into the mappings container; removed {len(stale)} no longer in the crosswalk")
    return 0


def report():
    """Coverage read back from the store and joined to the stored catalog, as markdown."""
    db = database()

    def query(container, sql):
        return list(db.get_container_client(container).query_items(sql, enable_cross_partition_query=True))

    rows = query("mappings", "SELECT c.sourceType, c.sourceId, c.targetIds, c.codePath FROM c "
                             f"WHERE c.frameworkId = '{FRAMEWORK_ID}'")
    functions = query("frameworks", "SELECT c.functionId, c.name, c.categories FROM c "
                                    f"WHERE c.frameworkId = '{FRAMEWORK_ID}' AND c.type = 'function'")
    if not rows:
        print("The mappings container is empty. Run labs/04-evidence/seed_mappings.py.")
        return 1
    order = list(CSF2_FUNCTIONS)
    functions.sort(key=lambda f: order.index(f["functionId"]) if f.get("functionId") in order else len(order))
    catalog = [(f.get("name"), c) for f in functions for c in f.get("categories") or []]
    covered = collections.defaultdict(list)
    for r in rows:
        for c in r.get("targetIds") or []:
            covered[c].append(r.get("sourceId") or "?")

    print(f"{len(rows)} controls mapped to {len(covered)} of the {len(catalog)} NIST CSF 2.0 categories.")
    print()
    print("| Function | Category | Controls | Which |")
    print("|---|---|---|---|")
    for name, c in catalog:
        if c in covered:
            ids = sorted(covered[c])
            print(f"| {name} | {c} | {len(ids)} | " + ", ".join(f"`{i}`" for i in ids) + " |")
    print()
    gaps = [c for _, c in catalog if c not in covered]
    if gaps:
        print("No control in this repo maps to " + ", ".join(gaps) + ".")
        print()

    entries = [(r.get("sourceType") or "?", r.get("sourceId") or "?", r.get("targetIds") or [],
                r.get("codePath") or "?") for r in rows]
    found = problems(entries, "the store", {c for _, c in catalog})
    if found:
        print("The crosswalk check found problems. Fix them before publishing this page:")
        print()
        for f in found:
            print(f"- {f}")
        return 1
    paths = {e[3] for e in entries}
    print("Crosswalk check passed: the store agrees with CONTROLS.md category by category, every "
          f"category is in the stored catalog, and every mapped control points at one of {len(paths)} "
          "files that exist in this repo.")
    return 0


def endpoint_set():
    if os.environ.get("COSMOS_ENDPOINT"):
        return True
    print("Set COSMOS_ENDPOINT first: terraform output -raw cosmos_endpoint, in stages/03-evidence-store.",
          file=sys.stderr)
    return False


def main():
    args = sys.argv[1:]
    if args not in ([], ["--check"], ["--report"]):
        print(__doc__)
        return 2
    if args == ["--report"]:
        return report() if endpoint_set() else 1

    found = problems(CROSSWALK, "the crosswalk", set(CATEGORIES))
    if found:
        print("The crosswalk and CONTROLS.md or the repo disagree, so nothing was written:", file=sys.stderr)
        for f in found:
            print(f"  - {f}", file=sys.stderr)
        return 1
    used = sorted({c for _, _, cats, _ in CROSSWALK for c in cats}, key=CATEGORIES.index)
    print(f"{len(CROSSWALK)} controls across {len(used)} CSF 2.0 categories ({', '.join(used)}): "
          "they match docs/CONTROLS.md, and every code path exists")
    if args == ["--check"]:
        return 0
    return seed() if endpoint_set() else 1


if __name__ == "__main__":
    raise SystemExit(main())
