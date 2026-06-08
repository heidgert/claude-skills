#!/usr/bin/env python3
"""Parse an Application Insights CSV export and summarise performance candidates.

Usage:
    python parser.py <csv_path>

Emits a single JSON document on stdout with one entry per request. Multiline
quoted SQL bodies in the `message` column are handled by the stdlib csv parser.

Output shape (truncated example):
{
  "requests": [
    {
      "operation": "GET MyAssignmentsQuery/GetElectDayAssignmentContactPersons",
      "operation_namespace": "Kaskelot.External.API.Controllers.MyAssignments.MyAssignmentsQueryController",
      "request_row": 2,
      "duration_ms": 35022.99,
      "result_code": "200",
      "deps_total_ms": 2999.86,
      "app_time_gap_ms": 32023.13,
      "dependencies": [
        {"row": 15, "duration_ms": 1953.33, "target": "...", "type": "SQL",
         "sql_signature": "SELECT [b].[Id] ... FROM [BemanningValdistrikt] AS [b] INNER JOIN ...",
         "sql_full": "<full normalized SQL>"}
      ],
      "duplicate_signatures": [
        {"signature": "SELECT [b].[Id] ... FROM [BemanningValdistrikt] ...",
         "count": 2, "rows": [15, 28], "total_ms": 2971.48}
      ]
    }
  ],
  "csv_rows": 52
}
"""
from __future__ import annotations

import csv
import json
import re
import sys
from collections import defaultdict
from pathlib import Path


SQL_PARAM_RE = re.compile(r"@__\w+_\d+|@p\d+|@\w+")
WS_RE = re.compile(r"\s+")
EXEC_ENDPOINT_RE = re.compile(r"Executing endpoint '([^']+) \(")
EXECUTED_DBCMD_RE = re.compile(
    r"Executed DbCommand \(([\d,]+)\s*ms\).*?\n(.*)", re.DOTALL
)


def normalize_sql(message: str) -> str | None:
    """Extract the SQL body from an 'Executed DbCommand' trace and normalise it.

    Strips parameter values, collapses whitespace. Returns None if not a SQL trace.
    """
    if "Executed DbCommand" not in message:
        return None
    m = EXECUTED_DBCMD_RE.search(message)
    if not m:
        return None
    sql = m.group(2)
    sql = SQL_PARAM_RE.sub("@p", sql)
    sql = WS_RE.sub(" ", sql).strip()
    return sql


def parse_duration(s: str) -> float:
    if not s:
        return 0.0
    return float(s.replace(",", ""))


def main(path: str) -> int:
    p = Path(path)
    if not p.exists():
        print(f"file not found: {path}", file=sys.stderr)
        return 2

    with p.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        rows = list(reader)

    expected = ["timestamp [UTC]", "itemType", "name", "duration",
                "resultCode", "message", "target", "type"]
    if header != expected:
        print(f"unexpected header: {header}\nexpected: {expected}", file=sys.stderr)
        return 3

    requests: list[dict] = []
    current: dict | None = None
    pending_dep: dict | None = None

    for idx, row in enumerate(rows, start=2):
        if len(row) < 8:
            continue
        ts, item_type, name, duration, result_code, message, target, dep_type = row

        if item_type == "request":
            if current is not None:
                requests.append(current)
            current = {
                "operation": name,
                "operation_namespace": None,
                "request_row": idx,
                "duration_ms": parse_duration(duration),
                "result_code": result_code,
                "deps_total_ms": 0.0,
                "app_time_gap_ms": 0.0,
                "dependencies": [],
                "duplicate_signatures": [],
            }
            pending_dep = None
            continue

        if current is None:
            continue

        if item_type == "dependency":
            pending_dep = {
                "row": idx,
                "duration_ms": parse_duration(duration),
                "target": target,
                "type": dep_type,
                "sql_signature": None,
                "sql_full": None,
            }
            current["dependencies"].append(pending_dep)
            current["deps_total_ms"] += pending_dep["duration_ms"]
            continue

        if item_type == "trace":
            if current["operation_namespace"] is None:
                m = EXEC_ENDPOINT_RE.search(message)
                if m:
                    current["operation_namespace"] = m.group(1)
            sig = normalize_sql(message)
            if sig and pending_dep is not None and pending_dep["sql_signature"] is None:
                pending_dep["sql_signature"] = sig
                pending_dep["sql_full"] = sig

    if current is not None:
        requests.append(current)

    for req in requests:
        req["app_time_gap_ms"] = round(
            req["duration_ms"] - req["deps_total_ms"], 2
        )
        req["deps_total_ms"] = round(req["deps_total_ms"], 2)

        sig_groups: dict[str, dict] = defaultdict(
            lambda: {"signature": "", "count": 0, "rows": [], "total_ms": 0.0}
        )
        for dep in req["dependencies"]:
            sig = dep["sql_signature"]
            if not sig:
                continue
            g = sig_groups[sig]
            g["signature"] = sig
            g["count"] += 1
            g["rows"].append(dep["row"])
            g["total_ms"] += dep["duration_ms"]
        req["duplicate_signatures"] = [
            {
                "signature": g["signature"],
                "count": g["count"],
                "rows": g["rows"],
                "total_ms": round(g["total_ms"], 2),
            }
            for g in sig_groups.values()
            if g["count"] >= 2
        ]
        req["duplicate_signatures"].sort(key=lambda g: g["total_ms"], reverse=True)

    print(json.dumps(
        {"requests": requests, "csv_rows": len(rows)},
        indent=2,
    ))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(64)
    sys.exit(main(sys.argv[1]))
