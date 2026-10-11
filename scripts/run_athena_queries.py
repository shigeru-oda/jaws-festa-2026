#!/usr/bin/env python3
"""Athena の「保存したクエリ」を名前の接頭辞で選んで順に実行し、結果を表で出す。

認証情報には触らない。AWS CLI に --profile を渡すだけで、資格情報の読み取りは
CLI 内部の SDK に任せる。

使い方:
  ./scripts/run_athena_queries.py --prefix drift_ --profile <プロファイル名>
  ./scripts/run_athena_queries.py --prefix drift_ --profile <名前> --tag gen1
      -> out/athena_drift_gen1.json に結果を書く

"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def aws(profile: str, region: str, *args: str) -> dict:
    cmd = ["aws", "--profile", profile, "--region", region, "--output", "json", *args]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:3])} が失敗: {p.stderr.strip()[-400:]}")
    return json.loads(p.stdout) if p.stdout.strip() else {}


def named_queries(profile: str, region: str, workgroup: str, prefix: str) -> list[dict]:
    ids: list[str] = []
    token = None
    while True:
        args = ["athena", "list-named-queries", "--work-group", workgroup]
        if token:
            args += ["--next-token", token]
        r = aws(profile, region, *args)
        ids += r.get("NamedQueryIds", [])
        token = r.get("NextToken")
        if not token:
            break
    out: list[dict] = []
    for i in range(0, len(ids), 50):
        r = aws(profile, region, "athena", "batch-get-named-query", "--named-query-ids", *ids[i : i + 50])
        out += r.get("NamedQueries", [])
    return sorted((q for q in out if q["Name"].startswith(prefix)), key=lambda q: q["Name"])


def run(profile: str, region: str, workgroup: str, q: dict, timeout: int = 120,
        database: str = "jaws_festa_2026_akita") -> dict:
    r = aws(
        profile, region, "athena", "start-query-execution",
        "--work-group", workgroup,
        "--query-execution-context", f"Database={database}",
        "--query-string", q["QueryString"],
    )
    qid = r["QueryExecutionId"]
    state, reason, scanned, ms = "QUEUED", "", 0, 0
    deadline = time.time() + timeout
    while time.time() < deadline:
        e = aws(profile, region, "athena", "get-query-execution", "--query-execution-id", qid)["QueryExecution"]
        state = e["Status"]["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            reason = e["Status"].get("StateChangeReason", "")
            scanned = e.get("Statistics", {}).get("DataScannedInBytes", 0)
            ms = e.get("Statistics", {}).get("TotalExecutionTimeInMillis", 0)
            break
        time.sleep(2)
    rows: list[list[str]] = []
    if state == "SUCCEEDED":
        token = None
        while True:
            args = ["athena", "get-query-results", "--query-execution-id", qid, "--max-items", "200"]
            if token:
                args += ["--starting-token", token]
            res = aws(profile, region, *args)
            for row in res["ResultSet"]["Rows"]:
                rows.append([c.get("VarCharValue", "") for c in row["Data"]])
            token = res.get("NextToken")
            if not token or len(rows) > 400:
                break
    return {
        "name": q["Name"],
        "description": q.get("Description", ""),
        "state": state,
        "reason": reason,
        "scanned_bytes": scanned,
        "millis": ms,
        "rows": rows,
    }


def show(r: dict, max_rows: int) -> None:
    head = f"■ {r['name']}  [{r['state']}]"
    if r["state"] == "SUCCEEDED":
        head += f"  {r['scanned_bytes']:,} bytes / {r['millis']:,} ms / {max(len(r['rows']) - 1, 0)} 行"
    print(head)
    if r["description"]:
        print(f"   {r['description']}")
    if r["state"] != "SUCCEEDED":
        print(f"   !! {r['reason'][:400]}")
        return
    if not r["rows"]:
        print("   (0 行)")
        return
    rows = r["rows"][: max_rows + 1]
    widths = [max(len(str(x[i])) if i < len(x) else 0 for x in rows) for i in range(len(rows[0]))]
    for n, row in enumerate(rows):
        cells = " | ".join(str(row[i] if i < len(row) else "").ljust(widths[i]) for i in range(len(widths)))
        print(f"   {cells}")
        if n == 0:
            print("   " + "-+-".join("-" * w for w in widths))
    rest = max(len(r["rows"]) - 1 - max_rows, 0)
    if rest:
        print(f"   … 他 {rest} 行")
    print()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", required=True)
    ap.add_argument("--region", default="ap-northeast-1")
    ap.add_argument("--workgroup", default="jaws-festa-2026")
    ap.add_argument("--database", default="jaws_festa_2026_akita")
    ap.add_argument("--prefix", default="drift_")
    ap.add_argument("--sql", default="", help="保存したクエリの代わりに .sql ファイルを流す")
    ap.add_argument("--tag", default="", help="out/athena_<prefix><tag>.json に結果を書く")
    ap.add_argument("--max-rows", type=int, default=12)
    a = ap.parse_args()

    if a.sql:
        # アドホック SQL。接頭辞はファイル名から取るので --tag だけで世代を分けられる。
        stem = os.path.splitext(os.path.basename(a.sql))[0]
        with open(a.sql, encoding="utf-8") as f:
            qs = [{"Name": stem, "QueryString": f.read(), "Description": f"{a.sql} をそのまま実行"}]
        a.prefix = f"{stem}_"
    else:
        qs = named_queries(a.profile, a.region, a.workgroup, a.prefix)
    if not qs:
        print(f"接頭辞 {a.prefix} の保存したクエリが見つからない", file=sys.stderr)
        return 1
    print(f"== {len(qs)} 本を実行する (workgroup={a.workgroup})\n")

    results = []
    for q in qs:
        r = run(a.profile, a.region, a.workgroup, q, database=a.database)
        results.append(r)
        show(r, a.max_rows)

    failed = [r["name"] for r in results if r["state"] != "SUCCEEDED"]
    total = sum(r["scanned_bytes"] for r in results)
    print(f"== 合計スキャン {total:,} bytes / 失敗 {len(failed)} 本")
    if failed:
        print("   " + ", ".join(failed))

    if a.tag:
        path = os.path.join(ROOT, "out", f"athena_{a.prefix}{a.tag}.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print(f"   -> {os.path.relpath(path, ROOT)}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
