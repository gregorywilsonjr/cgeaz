"""CGE-AZ pipeline — Stage 3 collector.

Timer fires nightly -> managed identity -> Defender assessments API -> Cosmos.
One document per assessment per run, upserted on a deterministic ID so re-runs
refresh instead of duplicate. Deliberately boring: if you can read this file,
you can defend this pipeline's data lineage.

Severity fix: the assessments LIST call does not return metadata (severity,
categories), so the collector joins it from Defender's metadata catalog.
"""

import datetime
import hashlib
import logging
import os
import uuid

import azure.functions as func
import requests
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()

ARM = "https://management.azure.com"
API_VERSION = "2021-06-01"


def _metadata_catalog(headers: dict) -> dict:
    """Assessment key -> metadata (severity, categories) for every built-in recommendation.

    One call per run. If it fails, _metadata_for() falls back to one lookup per
    assessment type, so a missing catalog never stops collection.
    """
    catalog = {}
    url = f"{ARM}/providers/Microsoft.Security/assessmentMetadata?api-version={API_VERSION}"
    try:
        while url:
            resp = requests.get(url, headers=headers, timeout=60)
            resp.raise_for_status()
            payload = resp.json()
            for item in payload.get("value", []):
                catalog[item["name"]] = item.get("properties", {})
            url = payload.get("nextLink")
    except requests.RequestException as exc:
        logging.warning("metadata catalog unavailable (%s); falling back per assessment", exc)
    return catalog


def _metadata_for(assessment: dict, catalog: dict, headers: dict) -> dict:
    """Metadata for one finding: the catalog first, else one GET with $expand=metadata."""
    key = assessment["name"]
    if key not in catalog:
        try:
            resp = requests.get(
                f"{ARM}{assessment['id']}?api-version={API_VERSION}&$expand=metadata",
                headers=headers,
                timeout=60,
            )
            resp.raise_for_status()
            catalog[key] = resp.json().get("properties", {}).get("metadata") or {}
        except requests.RequestException as exc:
            logging.warning("no metadata for %s (%s)", key, exc)
            catalog[key] = {}
    return catalog[key]


def _collect() -> dict:
    subscription_id = os.environ["SUBSCRIPTION_ID"]
    cosmos_endpoint = os.environ["COSMOS_ENDPOINT"]
    database = os.environ["COSMOS_DATABASE"]

    # DefaultAzureCredential resolves to the Function App's managed identity in Azure
    # (and to your `az login` session when run locally). No keys, anywhere.
    credential = DefaultAzureCredential()
    token = credential.get_token(f"{ARM}/.default").token
    headers = {"Authorization": f"Bearer {token}"}
    catalog = _metadata_catalog(headers)

    run_id = str(uuid.uuid4())
    collected_at = datetime.datetime.now(datetime.timezone.utc).isoformat()

    container = (
        CosmosClient(cosmos_endpoint, credential)
        .get_database_client(database)
        .get_container_client("assessments")
    )

    url = (
        f"{ARM}/subscriptions/{subscription_id}"
        f"/providers/Microsoft.Security/assessments?api-version={API_VERSION}"
    )
    written = 0
    while url:
        resp = requests.get(url, headers=headers, timeout=60)
        resp.raise_for_status()
        payload = resp.json()

        for assessment in payload.get("value", []):
            props = assessment.get("properties", {})
            meta = props.get("metadata") or _metadata_for(assessment, catalog, headers)
            resource_id = (
                props.get("resourceDetails", {}).get("Id")
                or props.get("resourceDetails", {}).get("id", "")
            )
            # Deterministic ID: same assessment+resource upserts, never duplicates.
            doc_id = hashlib.sha256(
                f"{assessment['name']}|{resource_id}".encode()
            ).hexdigest()[:32]

            container.upsert_item(
                {
                    "id": doc_id,
                    "subscriptionId": subscription_id,
                    "assessmentId": assessment["name"],
                    "displayName": props.get("displayName"),
                    "status": props.get("status", {}).get("code"),
                    "statusCause": props.get("status", {}).get("cause"),
                    "severity": meta.get("severity"),
                    "categories": meta.get("categories"),
                    "resourceId": resource_id,
                    "collectedAt": collected_at,
                    "runId": run_id,
                }
            )
            written += 1

        url = payload.get("nextLink")

    logging.info("collection run %s complete: %d documents", run_id, written)
    return {"runId": run_id, "written": written, "collectedAt": collected_at}


@app.timer_trigger(schedule="0 0 5 * * *", arg_name="timer", run_on_startup=False)
def collect_nightly(timer: func.TimerRequest) -> None:
    """Nightly sweep at 05:00 UTC — midnight-ish US Eastern."""
    _collect()


@app.route(route="collect", auth_level=func.AuthLevel.FUNCTION)
def collect_now(req: func.HttpRequest) -> func.HttpResponse:
    """Manual trigger for labs and demos: hit the endpoint, get the run summary."""
    result = _collect()
    return func.HttpResponse(
        f"run {result['runId']}: {result['written']} documents at {result['collectedAt']}\n",
        status_code=200,
    )
