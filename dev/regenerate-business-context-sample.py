#!/usr/bin/env python3
"""Regenerate dev/prod-business-context-sample.json from a LIVE environment.

The output is committed so `dev/seed-prod-like-business-context.sh` can make LOCAL match the
data SHAPE of prod (row counts, active/inactive mix, case-variant name pairs) without anyone
needing prod access.

Safety: it selects ONLY `name` + `is_active` (+ the product's BU name). It deliberately does NOT
touch legal_entities.details (EIN / officers / directors / ownership) — that must never land in git.

Usage (needs a Postgres connection string to the intake DB of the env you're sampling):
    INTAKE_DATABASE_URL='postgresql://...' python3 dev/regenerate-business-context-sample.py

If psycopg is unavailable, pass --from-json <file> where <file> holds the same shape, e.g. a
dump produced by the Supabase SQL editor.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys

OUT = pathlib.Path(__file__).resolve().parent / "prod-business-context-sample.json"

QUERY = """
select json_build_object(
  'entities', (select coalesce(json_agg(json_build_object('name', name, 'is_active', is_active)
                                        order by name), '[]'::json) from legal_entities),
  'business_units', (select coalesce(json_agg(json_build_object('name', name, 'is_active', is_active)
                                             order by name), '[]'::json) from business_units),
  'products', (select coalesce(json_agg(json_build_object('name', p.name,
                                                          'business_unit', bu.name,
                                                          'is_active', p.is_active)
                                        order by bu.name, p.name), '[]'::json)
               from products p join business_units bu on bu.id = p.business_unit_id)
) as payload
"""


def from_db(dsn: str) -> dict:
    try:
        import psycopg  # type: ignore
    except ImportError:  # pragma: no cover
        try:
            import psycopg2 as psycopg  # type: ignore
        except ImportError:
            sys.exit(
                "psycopg/psycopg2 not installed. Either `pip install psycopg[binary]` "
                "or run the query manually and use --from-json."
            )
    with psycopg.connect(dsn) as conn, conn.cursor() as cur:
        cur.execute(QUERY)
        row = cur.fetchone()
    if not row:
        sys.exit("query returned no rows")
    return dict(row[0])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from-json", help="read the payload from a file instead of querying a DB")
    args = ap.parse_args()

    payload: dict
    if args.from_json:
        raw = json.loads(pathlib.Path(args.from_json).read_text())
        # tolerate either the bare payload or a [{'payload': ...}] wrapper
        if isinstance(raw, list):
            if not raw:
                sys.exit("--from-json file contains an empty list")
            first = raw[0]
            raw = first.get("payload", first) if isinstance(first, dict) else first
        if not isinstance(raw, dict):
            sys.exit("--from-json payload must be a JSON object")
        payload = raw
    else:
        dsn = os.environ.get("INTAKE_DATABASE_URL")
        if not dsn:
            sys.exit("set INTAKE_DATABASE_URL or pass --from-json")
        payload = from_db(dsn)

    for key in ("entities", "business_units", "products"):
        if key not in payload:
            sys.exit(f"payload missing '{key}'")

    # Guard: never let a sensitive field slip into the committed sample.
    banned = {"details", "ein", "officers", "directors", "ownership", "address"}
    for key in ("entities", "business_units", "products"):
        for row in payload[key]:
            leaked = banned & {k.lower() for k in row}
            if leaked:
                sys.exit(f"ABORT: sensitive key(s) {sorted(leaked)} in {key}; refusing to write")

    OUT.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

    def counts(rows: list[dict]) -> str:
        active = sum(1 for r in rows if r.get("is_active"))
        return f"{active} active / {len(rows)} total"

    print(f"wrote {OUT}")
    print(f"  entities:       {counts(payload['entities'])}")
    print(f"  business_units: {counts(payload['business_units'])}")
    print(f"  products:       {counts(payload['products'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
