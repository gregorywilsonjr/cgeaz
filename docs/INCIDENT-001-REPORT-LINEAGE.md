# Incident 001: report numbers could not be reproduced from the store

**Status:** closed, 2026-09-21. A control failure in my own evidence plane, found by my own
evidence check, and recorded here rather than quietly corrected.

## Detection

2026-09-20. `scripts/capture-evidence.sh` re-runs every report's number against the store it
was built from:

```text
SELECT VALUE COUNT(1) FROM c WHERE c.runId = @run AND c.status = 'Unhealthy'
```

Both reports in the WORM `reports` container claimed 32 open findings for collection run
`2ef7fe8c`. The store returned 0 for that run. Two of two reports did not reproduce.

## Root cause

The collector wrote each assessment with a document ID of `<assessment>|<resourceId>`, with no
run in the key. Cosmos `upsert_item` therefore **overwrote** the previous run's documents on
every collection, and the store held one run at a time: the newest. Reports kept their `runId`
faithfully, so the lineage pointer was right and the rows it pointed at were gone.

Two design assumptions collided. "Collection is idempotent" was read as "one document per
assessment", when what idempotency needs is one document per assessment **per run**.

## Impact

Traceability, not accuracy. The two reports were correct when they were written. They cannot
be re-derived independently, which is the thing evidence has to allow. No finding was missed,
no number was wrong, and nothing outside the reporting lineage was affected.

A side effect on the run history: the reporter names each file by UTC date and never
overwrites, into a WORM container. Lab 5's manual reports had already taken the file names for
2026-09-20 at 01:13 UTC, so that day's 06:00 scheduled POA&M could not be written. The
scheduled series starts on 2026-09-21.

## Correction

The collector's document ID is now `<runId>|<assessment>|<resourceId>`, so every run is kept
and any report can be re-checked against the run it was built from
([PR #9](https://github.com/gregorywilsonjr/cgeaz/pull/9), commit `92ffc7b`).

Verified live the same day, before the next scheduled collection: runs `297f9d16` (05:00 UTC)
and `be9b5dc2` (07:45 UTC) each hold 58 documents in the store at the same time. Under the old
key the second run would have left 58 documents in total, not 116.

The two original reports stay exactly where they are. They are immutable for 90 days by the
container's own retention policy, and they are the evidence that this control failed and was
caught. `scripts/capture-evidence.sh` lists them on every run and counts them separately,
instead of dropping them from the ratio.

## Why there is no second reports container

Moving new reports into a fresh container would make the published ratio 100%. It would also
hide the only control failure this program has found in itself, and add a permanent
"authoritative container" caveat to three documents. Showing the failure, the root cause, the
fix and the clean runs after it is stronger evidence than a clean number.

## Closure criteria

- [x] Two collection runs coexist in the store, each complete. Verified 2026-09-20.
- [x] Reports written after the fix reproduce from the store. Verified 2026-09-21: the
      scheduled POA&M (06:00 UTC) and SAR (07:00 UTC), both built from run `f6dd764d`, each
      say 54 open findings, and the store returns 54 for that run.
- [x] The evidence page separates the two populations and names this record. 2026-09-21.
- [x] Both scheduled reports ran with no manual invocation in between. 2026-09-21.
