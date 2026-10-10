#!/usr/bin/env python3
"""Athena の CSV テーブルと同じ読み方を手元で再現し、
データを足したときに参照先がずれるかどうかを世代ごとに測る。

Athena(LazySimpleSerDe + skip.header.line.count=1)は
  - CSV の1行目を捨てる(ファイル側の見出しは一度も読まない)
  - テーブル定義の列を上から順に、CSV の列位置と突き合わせる
  - 定義より CSV の列が少なければ、余った定義列は NULL
  - 定義より CSV の列が多ければ、余った CSV 列は無視
  - bigint 列に数値として読めない値(`***` や空)が来たら NULL
この4つを再現してあるので、AWS に上げる前に期待値を確定できる。

terraform/athena_drift.tf の名前付きクエリは、ここで出した期待値をそのまま
Athena 上で再現することを狙っている。

使い方:
  ./scripts/verify_drift.py          # 測って out/drift_verification.json に書く
  ./scripts/verify_drift.py --check  # 測って期待値と突き合わせ、崩れたら非ゼロで落ちる
"""

from __future__ import annotations

import csv
import glob
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NENREI = os.path.join(ROOT, "data", "akita_nenreikakusai")
JKS = os.path.join(ROOT, "data", "akita_jinkousetai")
OUT = os.path.join(ROOT, "out", "drift_verification.json")

NULLS = {"", "***", "-", "…", "－"}


def header_of(path: str) -> list[str]:
    with open(path, "rb") as f:
        raw = f.read()
    rows = list(csv.reader(io.StringIO(raw.decode("utf-8-sig"))))
    return [c.strip() for c in rows[0]]


def scan(path: str, ncols: int) -> list[list[str | None]]:
    """Athena と同じ読み方。見出しを捨て、位置で ncols 列に揃える。"""
    with open(path, "rb") as f:
        raw = f.read()
    rows = list(csv.reader(io.StringIO(raw.decode("utf-8-sig"))))[1:]
    out = []
    for row in rows:
        vals: list[str | None] = []
        for i in range(ncols):
            v = row[i].strip() if i < len(row) else ""
            vals.append(None if v in NULLS else v)
        out.append(vals)
    return out


def as_int(v: str | None) -> int | None:
    if v is None:
        return None
    try:
        return int(v.replace(",", ""))
    except ValueError:
        return None


# ─────────────────────────────────────────────────────────────────────────────
# 1. 年齢各歳 — 列が消えるので参照先が物理的にずれる
# ─────────────────────────────────────────────────────────────────────────────
def nenreikakusai() -> dict:
    blocks = sorted(glob.glob(os.path.join(NENREI, "pref_nenreikakusai_*.csv")))
    if not blocks:
        sys.exit("data/akita_nenreikakusai/ が空。./scripts/fetch_nenreikakusai.sh を先に回すこと。")

    # テーブル定義は「2015ブロックまでを見て作った」128列。位置107が 年齢不詳。
    base = next(h for h in (header_of(p) for p in blocks) if len(h) == 128)
    POS_FUSHOU, POS_LAST = 107, 127
    assert base[POS_FUSHOU] == "年齢不詳", base[POS_FUSHOU]
    assert base[POS_LAST] == "95～99歳", base[POS_LAST]

    gen1 = [p for p in blocks if os.path.basename(p)[-8:-4] <= "2015"]
    gen2 = blocks  # 2020ブロック(127列)を足した状態

    def query(paths: list[str]) -> list[dict]:
        """SELECT 年, 年齢不詳, 95～99歳 WHERE 市町村='秋田県' AND 男女別='男女計（人）'"""
        rows = []
        for p in paths:
            for r in scan(p, 128):
                if r[3] == "秋田県" and r[4] == "男女計（人）":
                    rows.append(
                        {
                            "year": (r[1] or "")[:4],
                            "age_unknown": as_int(r[POS_FUSHOU]),
                            "age_95_99": as_int(r[POS_LAST]),
                            "block": os.path.basename(p)[-8:-4],
                        }
                    )
        return sorted(rows, key=lambda x: x["year"])

    before, after = query(gen1), query(gen2)
    seen = {r["year"] for r in before}
    added = [r for r in after if r["year"] not in seen]

    # 2020ブロックの行は、定義上 年齢不詳 のはずの欄に 0～4歳 の値が入る
    truth = {}
    for p in blocks:
        h = header_of(p)
        if len(h) != 127:
            continue
        for r in scan(p, 127):
            if r[3] == "秋田県" and r[4] == "男女計（人）":
                truth[(r[1] or "")[:4]] = {
                    "age_0_4": as_int(r[h.index("0～4歳")]),
                    "age_95_99": as_int(r[h.index("95～99歳")]),
                }

    mislabeled = [
        {
            "year": r["year"],
            "returned_as_age_unknown": r["age_unknown"],
            "actually_age_0_4": truth[r["year"]]["age_0_4"],
            "age_95_99_is_null": r["age_95_99"] is None,
            "true_age_95_99": truth[r["year"]]["age_95_99"],
        }
        for r in added
        if r["year"] in truth
    ]

    last_year_before = before[-1]

    # 逆向き: 127列の定義(2020ブロックを見て作り直した定義)で旧ブロックを読むと
    # 位置107以降が1つ右の名前にずれる。どちらの定義でも片側が壊れる。
    narrow = next(h for h in (header_of(p) for p in blocks) if len(h) == 127)
    assert narrow[107] == "0～4歳", narrow[107]
    reverse = []
    for p in blocks:
        h = header_of(p)
        for r in scan(p, 127):
            if r[3] != "秋田県" or r[4] != "男女計（人）":
                continue
            y = (r[1] or "")[:4]
            if y not in ("2019", "2020"):
                continue
            reverse.append(                {
                    "year": y,
                    "physical_columns": len(h),
                    "returned_as_age_cls_0_4": as_int(r[107]),
                    "returned_as_age_cls_95_99": as_int(r[126]),
                }
            )
    # 真の値を物理列数どおりに読んで添える
    for item in reverse:
        p = next(x for x in blocks if item["year"] in _years_of(x))
        h = header_of(p)
        for r in scan(p, len(h)):
            if r[3] == "秋田県" and r[4] == "男女計（人）" and (r[1] or "")[:4] == item["year"]:
                item["true_age_cls_0_4"] = as_int(r[h.index("0～4歳")])
                item["true_age_cls_95_99"] = as_int(r[h.index("95～99歳")])
                item["true_age_unknown"] = (
                    as_int(r[h.index("年齢不詳")]) if "年齢不詳" in h else None
                )
                break
    reverse_shifted = [
        i for i in reverse if i["returned_as_age_cls_0_4"] != i["true_age_cls_0_4"]
    ]

    return {
        "definition_columns": 128,
        "blocks_gen1": [os.path.basename(p)[-8:-4] for p in gen1],
        "blocks_gen2_added": sorted({os.path.basename(p)[-8:-4] for p in gen2} - {os.path.basename(p)[-8:-4] for p in gen1}),
        "years_gen1": len(before),
        "years_gen2": len(after),
        "last_sane_year": last_year_before["year"],
        "last_sane_age_unknown": last_year_before["age_unknown"],
        "added_rows": mislabeled,
        "all_added_mislabeled": all(
            m["returned_as_age_unknown"] == m["actually_age_0_4"] for m in mislabeled
        ),
        "all_added_last_column_null": all(m["age_95_99_is_null"] for m in mislabeled),
        "reverse_127_definition": reverse,
        "reverse_breaks_old_blocks": len(reverse_shifted) > 0,
    }


def _years_of(path: str) -> set[str]:
    h = header_of(path)
    return {(r[1] or "")[:4] for r in scan(path, len(h))}


# ─────────────────────────────────────────────────────────────────────────────
# 2. 月報人口 — 位置は動かないので、ずれるのは列名の意味だけ
# ─────────────────────────────────────────────────────────────────────────────
def jinkousetai() -> dict:
    files = sorted(glob.glob(os.path.join(JKS, "050008_jinkousetai_*.csv")))
    if not files:
        sys.exit("data/akita_jinkousetai/ が空。./scripts/fetch_jinkousetai.sh を先に回すこと。")

    old = next(h for h in (header_of(p) for p in files) if h[19].startswith("県外転入"))
    POS_TOTAL, POS_KENNAI, POS_KENGAI = 19, 22, 23
    assert old[POS_TOTAL] == "県外転入・男女計（人）", old[POS_TOTAL]
    assert old[POS_KENGAI] == "転入・県外計（人）", old[POS_KENGAI]

    gen1 = [p for p in files if "2008" <= os.path.basename(p)[-8:-4] <= "2023"]
    gen2 = files

    def query(paths: list[str]) -> dict[str, dict]:
        """SELECT 年, SUM(県外転入・男女計), SUM(転入・県外計) WHERE 市町村行のみ"""
        agg: dict[str, dict] = {}
        for p in paths:
            for r in scan(p, 36):
                kubun = r[3] or ""
                if kubun in ("県計", "市部計", "郡部計") or kubun.endswith("郡"):
                    continue
                t, g = as_int(r[POS_TOTAL]), as_int(r[POS_KENGAI])
                if t is None or g is None:
                    continue
                a = agg.setdefault((r[1] or "")[:4], {"labelled_kengai": 0, "true_kengai": 0, "rows": 0})
                a["labelled_kengai"] += t
                a["true_kengai"] += g
                a["rows"] += 1
        return dict(sorted(agg.items()))

    before, after = query(gen1), query(gen2)
    added = {y: v for y, v in after.items() if y not in before}

    # 旧名称の列が「県外転入」でない比率。世代をまたいでも同じ性質が続くことを見る
    def ratio(agg: dict[str, dict]) -> float:
        lab = sum(v["labelled_kengai"] for v in agg.values())
        tru = sum(v["true_kengai"] for v in agg.values())
        return lab / tru

    return {
        "definition_columns": 36,
        "definition_flavor": "旧名称(2008〜2023の見出し)",
        "years_gen1": sorted(before),
        "years_gen2_added": sorted(added),
        "overstatement_gen1": round(ratio(before), 4),
        "overstatement_gen2_added": round(ratio(added), 4),
        "overstatement_gen2_all": round(ratio(after), 4),
        "values_unchanged_for_existing_years": all(
            before[y] == after[y] for y in before
        ),
        "sample_added_year": {
            "year": sorted(added)[0] if added else None,
            **(added[sorted(added)[0]] if added else {}),
        },
    }


def main() -> int:
    check = "--check" in sys.argv
    nen, jks = nenreikakusai(), jinkousetai()

    print("■ 年齢各歳 — 128列の定義のまま 2020ブロックを足す")
    print(f"   世代1: {len(nen['blocks_gen1'])}ブロック / {nen['years_gen1']}年分")
    print(f"   世代2: +{','.join(nen['blocks_gen2_added'])}ブロック / {nen['years_gen2']}年分")
    print(f"   定義の最後の正常年 {nen['last_sane_year']}: 年齢不詳 = {nen['last_sane_age_unknown']:,}")
    print(f"   {'年':<6}{'年齢不詳として返る値':>22}{'実際は0〜4歳':>16}{'95〜99歳':>12}")
    for m in nen["added_rows"]:
        null = "NULL" if m["age_95_99_is_null"] else str(m["age_95_99_is_null"])
        print(f"   {m['year']:<6}{m['returned_as_age_unknown']:>22,}{m['actually_age_0_4']:>16,}{null:>12}")

    print()
    print("■ 年齢各歳 — 127列に作り直した定義で旧ブロックを読むと逆にずれる")
    print(f"   {'年':<6}{'物理列数':>10}{'0〜4歳として返る値':>22}{'真の0〜4歳':>14}{'真の年齢不詳':>14}")
    for i in nen["reverse_127_definition"]:
        tu = i["true_age_unknown"]
        print(
            f"   {i['year']:<6}{i['physical_columns']:>10}"
            f"{i['returned_as_age_cls_0_4']:>22,}{i['true_age_cls_0_4']:>14,}"
            f"{(f'{tu:,}' if tu is not None else '列なし'):>14}"
        )

    print()
    print("■ 月報人口 — 旧名称36列の定義のまま 2024〜2026 を足す")
    print(f"   世代1: {len(jks['years_gen1'])}年分 / 世代2: +{','.join(jks['years_gen2_added'])}")
    print(f"   既存年の値が変わったか: {'変わっていない' if jks['values_unchanged_for_existing_years'] else '変わった'}")
    print(f"   「県外転入」列 / 真の県外計: 世代1 {jks['overstatement_gen1']}倍 / 追加分 {jks['overstatement_gen2_added']}倍")

    failures = []
    if not nen["all_added_mislabeled"]:
        failures.append("年齢各歳: 追加ブロックの 年齢不詳 欄が 0〜4歳 の値になっていない")
    if not nen["all_added_last_column_null"]:
        failures.append("年齢各歳: 追加ブロックの最終列が NULL になっていない")
    if not nen["reverse_breaks_old_blocks"]:
        failures.append("年齢各歳: 127列定義が旧ブロックを壊していない(逆向きのずれが再現しない)")
    if not jks["values_unchanged_for_existing_years"]:
        failures.append("月報人口: 既存年の集計値が変わった(位置が動いたことになる)")
    if not 1.5 < jks["overstatement_gen2_added"] < 4.0:
        failures.append(f"月報人口: 追加分の過大率が {jks['overstatement_gen2_added']} で想定外")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"nenreikakusai": nen, "jinkousetai": jks}, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print()
    print(f"   -> {os.path.relpath(OUT, ROOT)}")

    if failures:
        print("\n!! 検証に失敗した:")
        for x in failures:
            print("   -", x)
        return 1
    if check:
        print("   OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
