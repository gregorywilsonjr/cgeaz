#!/usr/bin/env python3
"""The collection history, read back out of the evidence store.

One line per collection run the store still holds, with what it wrote and how many
findings were open, then what closed and what opened between the first run kept and
the newest one. A night the collector wrote nothing shows up as a missing row rather
than as silence: every report names the run it was built from, so a gap is visible
and no report invents data.

    python3 run_history.py    # needs COSMOS_ENDPOINT (a stage 03 output)

It runs as you, over Entra ID: the evidence database takes no keys.
"""

import os
import sys
from collections import Counter


def main() -> int:
    from azure.cosmos import CosmosClient
    from azure.identity import DefaultAzureCredential

    endpoint = os.environ.get("COSMOS_ENDPOINT")
    if not endpoint:
        print("COSMOS_ENDPOINT is not set: terraform output -raw cosmos_endpoint in stages/03-evidence-store.")
        return 1

    container = (
        CosmosClient(endpoint, DefaultAzureCredential())
        .get_database_client(os.environ.get("COSMOS_DATABASE", "grc"))
        .get_container_client("assessments")
    )
    rows = list(
        container.query_items(
            "SELECT c.runId, c.collectedAt, c.status, c.displayName, c.resourceId FROM c",
            enable_cross_partition_query=True,
        )
    )
    if not rows:
        print("The assessments container is empty.")
        return 1

    when, documents, open_findings = {}, Counter(), Counter()
    for row in rows:
        when.setdefault(row["runId"], row["collectedAt"])
        documents[row["runId"]] += 1
        if row.get("status") == "Unhealthy":
            open_findings[row["runId"]] += 1
    runs = sorted(documents, key=lambda run: when[run])

    print(f"{len(runs)} collection runs retained, {len(rows)} documents in all.")
    print()
    print("| Collected (UTC) | Run | Documents | Open findings |")
    print("|---|---|---|---|")
    for run in runs:
        print(f"| {when[run][:19]} | `{run[:8]}` | {documents[run]} | {open_findings[run]} |")

    def unhealthy(run):
        return {
            (row.get("displayName"), (row.get("resourceId") or "").rsplit("/", 1)[-1])
            for row in rows
            if row["runId"] == run and row.get("status") == "Unhealthy"
        }

    print()
    print("What changed from one run to the next:")
    print()
    print("| From | To | Findings closed | Findings opened |")
    print("|---|---|---|---|")
    closed_when = []
    for older, newer in zip(runs, runs[1:]):
        gone = unhealthy(older) - unhealthy(newer)
        new_ones = unhealthy(newer) - unhealthy(older)
        closed_when += [(when[newer][:10], name, resource) for name, resource in sorted(gone)]
        print(f"| {when[older][:10]} | {when[newer][:10]} | {len(gone)} | {len(new_ones)} |")

    print()
    if closed_when:
        print("Every finding that closed while these runs were kept, and the run that first reported it fixed:")
        print()
        for day, name, resource in closed_when[:20]:
            print(f"- {day}: {name} on `{resource}`")
        if len(closed_when) > 20:
            print(f"- and {len(closed_when) - 20} more")
    else:
        print("No finding closed while these runs were kept.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
