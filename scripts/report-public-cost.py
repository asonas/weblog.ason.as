"""Summarize cached operation logs and CUR CSV files without network requests."""

import argparse
import csv
from collections import defaultdict
from decimal import Decimal
import gzip
import json
from pathlib import Path


def read_text(path):
    return gzip.open(path, "rt", encoding="utf-8") if str(path).endswith(".gz") else open(path, encoding="utf-8")


def report(operation_files, cost_files, start, end):
    operations = defaultdict(lambda: {"samples": 0, "estimated_operations": 0.0,
        "estimated_sql_count": 0.0, "estimated_sql_errors": 0.0, "estimated_db_retries": 0.0,
        "sample_sql_ms": 0.0, "durations": [], "log_bytes": 0})
    seen_requests = set()
    for path in operation_files:
        with read_text(path) as source:
            payload = json.load(source)
        if payload.get("nextToken") or payload.get("NextToken"):
            raise ValueError(f"Incomplete log export: {path}")
        for record in payload.get("events", []):
            message = record["message"]
            opening = message.find("{")
            if opening < 0:
                continue
            entry = json.loads(message[opening:])
            if entry.get("event") != "operation_metrics":
                continue
            day = entry["timestamp"][:10]
            if not start <= day < end:
                continue
            identity = (entry.get("function"), entry["request_id"])
            if identity in seen_requests:
                continue
            seen_requests.add(identity)
            rate = float(entry["sample_rate"])
            if not 0 < rate <= 1:
                raise ValueError("Invalid sample rate")
            key = (day, entry.get("function"), entry["workload"], entry.get("delivery"), entry.get("code_revision"))
            row = operations[key]
            row["samples"] += 1
            row["estimated_operations"] += 1 / rate
            row["estimated_sql_count"] += entry["sql_count"] / rate
            row["estimated_sql_errors"] += entry["sql_errors"] / rate
            row["estimated_db_retries"] += entry["db_retries"] / rate
            row["sample_sql_ms"] += entry["sql_ms"]
            row["durations"].append(entry["duration_ms"])
            row["log_bytes"] += len(message.encode("utf-8"))

    costs = defaultdict(lambda: {"usage": Decimal(0), "cost": Decimal(0)})
    seen_items = {}
    for path in cost_files:
        with read_text(path) as source:
            for item in csv.DictReader(source):
                day = item["line_item_usage_start_date"][:10]
                if not start <= day < end:
                    continue
                identity = (item["identity_line_item_id"], item["line_item_usage_start_date"],
                    item.get("line_item_usage_end_date"))
                if identity in seen_items:
                    if seen_items[identity] != item:
                        raise ValueError("Conflicting CUR revisions; use files from one manifest only")
                    continue
                seen_items[identity] = item
                key = (day, item["line_item_product_code"], item["line_item_resource_id"],
                    item["line_item_usage_type"], item["line_item_line_item_type"],
                    item["pricing_unit"], item["line_item_currency_code"])
                row = costs[key]
                row["usage"] += Decimal(item["line_item_usage_amount"])
                row["cost"] += Decimal(item["line_item_unblended_cost"])

    output = []
    for key, row in sorted(operations.items(), key=lambda pair: str(pair[0])):
        durations = sorted(row.pop("durations"))
        row["sample_mean_duration_ms"] = sum(durations) / len(durations)
        output.append(dict(zip(["day", "function", "workload", "delivery", "code_revision"], key)) | row)
    return {
        "start_inclusive": start, "end_exclusive": end,
        "operations": output,
        "costs": [dict(zip(["day", "service", "resource", "usage_type", "line_item_type", "unit", "currency"], key)) |
            {"usage": str(row["usage"]), "unblended_cost": str(row["cost"])}
            for key, row in sorted(costs.items())],
        "limitations": ["Sampled operation totals are estimates, not billing units.",
            "SQL count and duration cannot allocate cluster DPU charges to requests.",
            "Missing days or samples are unknown, not zero. CUR may be revised before billing closes.",
            "Includes only instrumented Lambda calls; local scripts and other cluster users are not attributed."],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operations", action="append", type=Path, default=[])
    parser.add_argument("--cur", action="append", type=Path, default=[])
    parser.add_argument("--start", required=True, help="UTC YYYY-MM-DD, inclusive")
    parser.add_argument("--end", required=True, help="UTC YYYY-MM-DD, exclusive")
    args = parser.parse_args()
    if not args.operations and not args.cur:
        parser.error("Provide cached --operations and/or --cur files")
    print(json.dumps(report(args.operations, args.cur, args.start, args.end), ensure_ascii=False, indent=2))
