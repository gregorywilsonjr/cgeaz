#!/usr/bin/env python3
"""Seed the frameworks container with the NIST CSF 2.0 structure.

Run once after deploying stages/03-evidence-store:

    pip install azure-cosmos azure-identity
    COSMOS_ENDPOINT=$(cd ../../stages/03-evidence-store && terraform output -raw cosmos_endpoint) \
        python3 seed_frameworks.py

Authenticates as YOU (az login) — the deployer's Cosmos data role comes from the stage.
The crosswalk goes into the mappings container with seed_mappings.py, next to this file,
which reads its category catalog from CSF2_FUNCTIONS below. The Azure SDK is imported
inside main() so that catalog loads without it: seed_mappings.py --check runs in CI.
"""

import os
import sys

CSF2_FUNCTIONS = {
    "GV": ("Govern", ["GV.OC", "GV.RM", "GV.RR", "GV.PO", "GV.OV", "GV.SC"]),
    "ID": ("Identify", ["ID.AM", "ID.RA", "ID.IM"]),
    "PR": ("Protect", ["PR.AA", "PR.AT", "PR.DS", "PR.PS", "PR.IR"]),
    "DE": ("Detect", ["DE.CM", "DE.AE"]),
    "RS": ("Respond", ["RS.MA", "RS.AN", "RS.CO", "RS.MI"]),
    "RC": ("Recover", ["RC.RP", "RC.CO"]),
}


def main() -> int:
    endpoint = os.environ.get("COSMOS_ENDPOINT")
    if not endpoint:
        print("Set COSMOS_ENDPOINT (see docstring).", file=sys.stderr)
        return 1

    from azure.cosmos import CosmosClient
    from azure.identity import DefaultAzureCredential

    container = (
        CosmosClient(endpoint, DefaultAzureCredential())
        .get_database_client(os.environ.get("COSMOS_DATABASE", "grc"))
        .get_container_client("frameworks")
    )

    written = 0
    for func_id, (name, categories) in CSF2_FUNCTIONS.items():
        container.upsert_item(
            {
                "id": f"csf2-{func_id}",
                "frameworkId": "nist-csf-2.0",
                "type": "function",
                "functionId": func_id,
                "name": name,
                "categories": categories,
            }
        )
        written += 1

    container.upsert_item(
        {
            "id": "nist-csf-2.0",
            "frameworkId": "nist-csf-2.0",
            "type": "framework",
            "name": "NIST Cybersecurity Framework 2.0",
            "functions": list(CSF2_FUNCTIONS.keys()),
        }
    )
    print(f"seeded {written + 1} framework documents into {endpoint}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
