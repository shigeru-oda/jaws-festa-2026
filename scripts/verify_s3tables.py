#!/usr/bin/env python3
"""スライドの Iceberg / S3 Tables 側の主張を、実機の Athena + S3 Tables で確かめる。

    ./scripts/verify_s3tables.py --profile <名前>            # 確かめて out/s3tables_verification.json に書く
    ./scripts/verify_s3tables.py --profile <名前> --keep     # 検証用のテーブルを消さずに残す

確かめること(スライドの表の1行ずつに対応):

- schema: 列の名前変更 / 削除 / 先頭・中間に追加 / 順序変更 / 型の変更 で、既存の値が正しく読めるか
- table:  書くときのスキーマ検査 / snapshot の履歴 / time travel / 失敗した書き込みが残らないか /
          UPDATE・DELETE・MERGE INTO
- speed:  同じ集計を bronze(CSV, 汎用バケット)と silver(S3 Tables)で5回ずつ実行した時間とスキャン量

テーブルバケット jaws-festa-2026-silver に名前空間 `verify` を作り、その中に使い捨てのテーブルを作る。
silver の既存テーブル(akita 名前空間)には読み取りしかしない。終わったら名前空間ごと消し、
付けた Lake Formation の権限も取り消す(--keep を付けない限り)。

AWS CLI を呼ぶだけなので標準ライブラリで動く。
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGION = "ap-northeast-1"
WORKGROUP = "jaws-festa-2026"
BUCKET = "jaws-festa-2026-silver"
NS = "verify"
CAT = f'"s3tablescatalog/{BUCKET}"'
GLUE_DB = "jaws_festa_2026_akita"


class Aws:
    def __init__(self, profile: str):
        self.profile = profile

    def __call__(self, *args: str, ok_fail: bool = False) -> dict:
        p = subprocess.run(["aws", "--profile", self.profile, "--region", REGION, "--output", "json", *args],
                           capture_output=True, text=True)
        if p.returncode != 0:
            if ok_fail:
                return {"_error": p.stderr.strip()[-300:]}
            raise RuntimeError(f"aws {' '.join(args[:2])} が失敗: {p.stderr.strip()[-400:]}")
        return json.loads(p.stdout) if p.stdout.strip() else {}


def athena(aws: Aws, sql: str, catalog: str | None = None) -> dict:
    """1本流して、状態・行・統計を返す。失敗も結果として返す(失敗すること自体を確かめる場合があるため)。"""
    args = ["athena", "start-query-execution", "--work-group", WORKGROUP, "--query-string", sql]
    if catalog:
        args += ["--query-execution-context", json.dumps({"Catalog": catalog, "Database": NS})]
    qid = aws(*args)["QueryExecutionId"]
    while True:
        q = aws("athena", "get-query-execution", "--query-execution-id", qid)["QueryExecution"]
        state = q["Status"]["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        time.sleep(1)
    out = {
        "sql": " ".join(sql.split()),
        "state": state,
        "error": q["Status"].get("StateChangeReason"),
        "engine_ms": q.get("Statistics", {}).get("EngineExecutionTimeInMillis"),
        "total_ms": q.get("Statistics", {}).get("TotalExecutionTimeInMillis"),
        "scanned_bytes": q.get("Statistics", {}).get("DataScannedInBytes"),
    }
    if state == "SUCCEEDED" and q.get("StatementType") == "DML":
        rows = aws("athena", "get-query-results", "--query-execution-id", qid)["ResultSet"]["Rows"]
        out["rows"] = [[c.get("VarCharValue") for c in r["Data"]] for r in rows[1:]]
    return out


def must(r: dict) -> dict:
    if r["state"] != "SUCCEEDED":
        raise RuntimeError(f"想定外の失敗: {r['sql']}\n  {r['error']}")
    return r


# ── 準備と後始末 ──────────────────────────────────────────────────────────────
def principal(aws: Aws) -> str:
    arn = aws("sts", "get-caller-identity")["Arn"]
    if ":assumed-role/" in arn:
        return aws("iam", "get-role", "--role-name", arn.split("/")[1])["Role"]["Arn"]
    return arn


def lf_resources(account: str) -> list[tuple[dict, list[str]]]:
    cat_id = f"{account}:s3tablescatalog/{BUCKET}"
    return [
        ({"Catalog": {"Id": cat_id}}, ["DESCRIBE"]),
        ({"Database": {"CatalogId": cat_id, "Name": NS}}, ["ALL"]),
        ({"Table": {"CatalogId": cat_id, "DatabaseName": NS, "TableWildcard": {}}}, ["ALL"]),
    ]


def setup(aws: Aws, bucket_arn: str, account: str, who: str) -> None:
    aws("s3tables", "create-namespace", "--table-bucket-arn", bucket_arn, "--namespace", NS, ok_fail=True)
    for res, perms in lf_resources(account):
        aws("lakeformation", "grant-permissions", "--principal", json.dumps({"DataLakePrincipalIdentifier": who}),
            "--resource", json.dumps(res), "--permissions", json.dumps(perms), ok_fail=True)
    time.sleep(5)  # 権限が反映されるまで少し待つ


def teardown(aws: Aws, bucket_arn: str, account: str, who: str) -> None:
    tables = aws("s3tables", "list-tables", "--table-bucket-arn", bucket_arn, "--namespace", NS,
                 ok_fail=True).get("tables", [])
    for t in tables:
        aws("s3tables", "delete-table", "--table-bucket-arn", bucket_arn, "--namespace", NS, "--name", t["name"])
    aws("s3tables", "delete-namespace", "--table-bucket-arn", bucket_arn, "--namespace", NS, ok_fail=True)
    for res, perms in reversed(lf_resources(account)):
        aws("lakeformation", "revoke-permissions", "--principal", json.dumps({"DataLakePrincipalIdentifier": who}),
            "--resource", json.dumps(res), "--permissions", json.dumps(perms), ok_fail=True)


# ── 検証 ─────────────────────────────────────────────────────────────────────
def T(name: str) -> str:
    return f"{CAT}.{NS}.{name}"


def create(aws: Aws, name: str, cols: str) -> None:
    athena(aws, f"DROP TABLE IF EXISTS {NS}.{name}", catalog=f"s3tablescatalog/{BUCKET}")
    must(athena(aws, f"CREATE TABLE {NS}.{name} ({cols}) TBLPROPERTIES ('table_type' = 'iceberg')",
                catalog=f"s3tablescatalog/{BUCKET}"))


def ddl(aws: Aws, sql: str) -> dict:
    return athena(aws, sql, catalog=f"s3tablescatalog/{BUCKET}")


def rows(aws: Aws, sql: str) -> list[list]:
    return must(athena(aws, sql))["rows"]


def schema_changes(aws: Aws) -> list[dict]:
    """スライド「Parquet化すれば〜」の Iceberg 列。旧データは id, a=10, b=20, c=30 の1行。"""
    out = []

    def case(label: str, slide: str, change: list[str], new_insert: str | None, check: str, expect):
        tbl = "s_" + str(len(out))
        create(aws, tbl, "id int, a int, b int, c int")
        must(athena(aws, f"INSERT INTO {T(tbl)} VALUES (1, 10, 20, 30)"))
        results = [ddl(aws, s.format(t=f"{NS}.{tbl}")) for s in change]
        if new_insert:
            results.append(athena(aws, new_insert.format(t=T(tbl))))
        got = rows(aws, check.format(t=T(tbl))) if all(r["state"] == "SUCCEEDED" for r in results) else None
        out.append({
            "case": label, "slide_claim": slide,
            "steps": [{"sql": r["sql"], "state": r["state"], "error": r["error"]} for r in results],
            "check": check.format(t=T(tbl)), "got": got, "expected": expect, "ok": got == expect,
        })

    case("列の名前変更", "影響なし",
         ["ALTER TABLE {t} CHANGE COLUMN b b_renamed int"],
         "INSERT INTO {t} VALUES (2, 11, 21, 31)",
         "SELECT id, b_renamed, c FROM {t} ORDER BY id",
         [["1", "20", "30"], ["2", "21", "31"]])
    case("列の削除(列を落とす)", "NULL(正しい)",
         ["ALTER TABLE {t} DROP COLUMN b"],
         "INSERT INTO {t} VALUES (2, 11, 31)",
         "SELECT id, a, c FROM {t} ORDER BY id",
         [["1", "10", "30"], ["2", "11", "31"]])
    case("列の削除(新しいデータに列が無い)", "NULL(正しい)",
         [],
         "INSERT INTO {t} (id, a, c) VALUES (2, 11, 31)",
         "SELECT id, a, b, c FROM {t} ORDER BY id",
         [["1", "10", "20", "30"], ["2", "11", None, "31"]])
    case("先頭・中間に列を追加", "影響なし",
         ["ALTER TABLE {t} ADD COLUMNS (x int)", "ALTER TABLE {t} CHANGE COLUMN x x int AFTER a"],
         "INSERT INTO {t} VALUES (2, 11, 99, 21, 31)",
         "SELECT id, a, x, b, c FROM {t} ORDER BY id",
         [["1", "10", None, "20", "30"], ["2", "11", "99", "21", "31"]])
    case("列の順序変更", "影響なし",
         ["ALTER TABLE {t} CHANGE COLUMN c c int AFTER id"],
         "INSERT INTO {t} VALUES (2, 31, 11, 21)",
         "SELECT id, a, b, c FROM {t} ORDER BY id",
         [["1", "10", "20", "30"], ["2", "11", "21", "31"]])
    case("列の型の変更(int → bigint)", "(表には無い)",
         ["ALTER TABLE {t} CHANGE COLUMN c c bigint"],
         "INSERT INTO {t} VALUES (2, 11, 21, 3000000000)",
         "SELECT id, c FROM {t} ORDER BY id",
         [["1", "30"], ["2", "3000000000"]])
    return out


def table_features(aws: Aws) -> list[dict]:
    """スライド「Parquet で足りるか、Iceberg にするか」の右列。"""
    out = []
    tbl = "f_table"
    create(aws, tbl, "id int, city string, pop int")
    must(athena(aws, f"INSERT INTO {T(tbl)} VALUES (1, '秋田市', 300000), (2, '能代市', 50000)"))
    snaps = lambda: rows(aws, f'SELECT snapshot_id, operation FROM {CAT}.{NS}."{tbl}$snapshots" ORDER BY committed_at')  # noqa: E731
    count = lambda: rows(aws, f"SELECT count(*) FROM {T(tbl)}")[0][0]  # noqa: E731
    s1 = snaps()

    # 書くときのスキーマ検査: 列数が合わない / 型が合わない
    bad_arity = athena(aws, f"INSERT INTO {T(tbl)} VALUES (3, '横手市')")
    bad_type = athena(aws, f"INSERT INTO {T(tbl)} VALUES (3, '横手市', 'たくさん')")
    s2 = snaps()
    out.append({
        "item": "スキーマの検査(書くときに検査。合わない DML は失敗する)",
        "evidence": {"列数が合わない INSERT": [bad_arity["state"], bad_arity["error"]],
                     "型が合わない INSERT": [bad_type["state"], bad_type["error"]],
                     "失敗後の snapshot 数": [len(s1), len(s2)], "失敗後の行数": count()},
        "ok": bad_arity["state"] == "FAILED" and bad_type["state"] == "FAILED" and len(s1) == len(s2),
    })

    # UPDATE / DELETE / MERGE INTO
    u = athena(aws, f"UPDATE {T(tbl)} SET pop = 299000 WHERE id = 1")
    d = athena(aws, f"DELETE FROM {T(tbl)} WHERE id = 2")
    m = athena(aws, f"""MERGE INTO {T(tbl)} t USING (VALUES (1, '秋田市', 298000), (3, '横手市', 85000)) AS s(id, city, pop)
        ON t.id = s.id WHEN MATCHED THEN UPDATE SET pop = s.pop WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.city, s.pop)""")
    after = rows(aws, f"SELECT id, city, pop FROM {T(tbl)} ORDER BY id")
    out.append({
        "item": "遡った訂正(UPDATE / DELETE / MERGE INTO)",
        "evidence": {"UPDATE": u["state"], "DELETE": d["state"], "MERGE INTO": m["state"], "結果": after},
        "ok": all(x["state"] == "SUCCEEDED" for x in (u, d, m))
        and after == [["1", "秋田市", "298000"], ["3", "横手市", "85000"]],
    })

    # snapshot の履歴と time travel
    s3 = snaps()
    first = s1[0][0]
    tt = must(athena(aws, f"SELECT id, city, pop FROM {T(tbl)} FOR VERSION AS OF {first} ORDER BY id"))["rows"]
    hist = rows(aws, f'SELECT made_current_at, snapshot_id, is_current_ancestor FROM {CAT}.{NS}."{tbl}$history" ORDER BY made_current_at')
    out.append({
        "item": "snapshot に履歴が残る / time travel(snapshot ID)",
        "evidence": {"snapshot(操作の順)": [op for _, op in s3], "最初の snapshot に戻した結果": tt,
                     "$history の件数": len(hist)},
        "ok": tt == [["1", "秋田市", "300000"], ["2", "能代市", "50000"]] and len(s3) >= 4,
    })

    # 列が消えたことが履歴に残るか(スライド「snapshot に残る(いつ消えたか分かる)」)
    must(ddl(aws, f"ALTER TABLE {NS}.{tbl} DROP COLUMN pop"))
    now_cols = must(athena(aws, f"SELECT * FROM {T(tbl)} ORDER BY id"))["rows"]
    tt_cols = athena(aws, f"SELECT * FROM {T(tbl)} FOR VERSION AS OF {first} ORDER BY id")
    out.append({
        "item": "列が消えた後に、消える前の snapshot を読む",
        "evidence": {"今の SELECT *": now_cols, "最初の snapshot の SELECT *": tt_cols.get("rows"),
                     "state": tt_cols["state"], "error": tt_cols["error"]},
        "note": "列を落とした後でも、最初の snapshot を指定すると消える前の列(pop)ごと読めた。"
                "列の削除そのものはデータの snapshot ではなくスキーマの版の変更なので、$snapshots には現れない",
        "ok": tt_cols.get("rows") == [["1", "秋田市", "300000"], ["2", "能代市", "50000"]],
    })
    return out


def speed(aws: Aws, runs: int) -> dict:
    """bronze(CSV, Glue)と silver(S3 Tables)で同じ集計を runs 回ずつ。"""
    where = "shichoson = '秋田県' AND danjo = '男女計（人）'"
    qs = {
        "bronze_csv": f"SELECT substr(nengetsubi, 1, 4) y, sum(CAST(age_cls_0_4 AS bigint)) "
                      f"FROM {GLUE_DB}.bronze_nenreikakusai WHERE {where} AND regexp_like(age_cls_0_4, '^[0-9]+$') "
                      f"GROUP BY 1 ORDER BY 1",
        "silver_s3tables": f"SELECT substr(nengetsubi, 1, 4) y, sum(age_cls_0_4) "
                           f"FROM {CAT}.akita.silver_nenreikakusai WHERE {where} GROUP BY 1 ORDER BY 1",
    }
    out = {}
    for name, sql in qs.items():
        rs = [must(athena(aws, sql)) for _ in range(runs)]
        out[name] = {
            "sql": rs[0]["sql"],
            "engine_ms": [r["engine_ms"] for r in rs],
            "total_ms": [r["total_ms"] for r in rs],
            "engine_ms_median": statistics.median(r["engine_ms"] for r in rs),
            "total_ms_median": statistics.median(r["total_ms"] for r in rs),
            "scanned_bytes": rs[0]["scanned_bytes"],
            "result_rows": len(rs[0]["rows"]),
        }
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--keep", action="store_true", help="検証用の名前空間とテーブル・権限を残す")
    args = ap.parse_args()
    aws = Aws(args.profile)

    account = aws("sts", "get-caller-identity")["Account"]
    bucket_arn = f"arn:aws:s3tables:{REGION}:{account}:bucket/{BUCKET}"
    who = principal(aws)
    setup(aws, bucket_arn, account, who)
    try:
        result = {
            "measured_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "region": REGION,
            "engine": "Amazon Athena (Iceberg on S3 Tables)",
            "schema_changes": schema_changes(aws),
            "table_features": table_features(aws),
            "speed": speed(aws, args.runs),
        }
    finally:
        if not args.keep:
            teardown(aws, bucket_arn, account, who)
    text = json.dumps(result, ensure_ascii=False, indent=1).replace(account, "<account>")
    (ROOT / "out" / "s3tables_verification.json").write_text(text + "\n", encoding="utf-8")
    for c in result["schema_changes"]:
        print(f"{'OK ' if c['ok'] else 'NG '} {c['case']:<26} スライド: {c['slide_claim']:<10} 実測: {c['got']}")
        for s in c["steps"]:
            if s["state"] != "SUCCEEDED":
                print("     ", s["state"], s["sql"][:80], "|", (s["error"] or "")[:160])
    for f in result["table_features"]:
        print(f"{'OK ' if f['ok'] else ('-- ' if f['ok'] is None else 'NG ')} {f['item']}")
        print("     ", json.dumps(f["evidence"], ensure_ascii=False)[:400])
    for k, v in result["speed"].items():
        print(f"{k:<16} engine 中央値 {v['engine_ms_median']} ms / total 中央値 {v['total_ms_median']} ms / "
              f"スキャン {v['scanned_bytes']:,} bytes  ({v['engine_ms']})")
    print("-> out/s3tables_verification.json")


if __name__ == "__main__":
    main()
