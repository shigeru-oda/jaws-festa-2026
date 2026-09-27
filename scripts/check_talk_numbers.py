"""登壇原稿の数字が実測値と一致しているかを検査する回帰ガード。

`docs/talk-script.md` に書いた数字は、すべて `out/*.json`(ノートブックの出力)が
根拠になっている。データを取り直したり集計を変えたりすると原稿だけが古くなるので、
機械的に突き合わせる。

    uv run python scripts/check_talk_numbers.py

検査は4種類:

1. **必須の数字** -- JSON から計算した値が、文脈付きのパターンで本文に出現するか
   (`11` のような小さい数は「11ファイル」まで含めて照合する。ただの `11` だと
   「11理由」に誤マッチして通ってしまう)
2. **ベンチ値** -- 実行ごとに揺れるので ±25% の許容差で照合する
3. **禁止の数字** -- 別テーブルの実測値(12.4KB / 2.3ms)が本文に混ざっていないか
4. **尺の整合** -- 見出しの時刻が「話す」文字数から再計算した値と合うか

セルフチェック節は本文から除外する(そこでは禁止の数字にあえて言及しているため)。
終了コードは、失敗が1件でもあれば 1。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "docs" / "talk-script.md"
OUT = ROOT / "out"

CPM = 300
OVERHEAD = 1.10
MIN_SLIDE_SECS = 20
TOLERANCE_SECS = 3
BENCH_TOLERANCE = 0.25  # ベンチ値の許容差(相対)

HEADER_RE = re.compile(r"^## (S\d+) — (.+?) \((\d+):(\d+)-(\d+):(\d+) / (\d+)秒\)\s*$")


def load(name: str) -> dict:
    return json.loads((OUT / name).read_text(encoding="utf-8"))


def split_script() -> tuple[str, dict[str, str], list[tuple[str, int]]]:
    body: list[str] = []
    spoken: dict[str, list[str]] = {}
    headers: list[tuple[str, int]] = []
    cur: str | None = None
    in_body = True

    for line in SCRIPT.read_text(encoding="utf-8").splitlines():
        if line.startswith("## セルフチェック"):
            in_body = False
            cur = None
        m = HEADER_RE.match(line)
        if m:
            cur = m.group(1)
            spoken[cur] = []
            headers.append((cur, int(m.group(7))))
            continue
        if in_body:
            body.append(line)
        if cur and line.startswith("> ") and "**話す**" not in line and "【要実測】" not in line:
            spoken[cur].append(line[2:].strip())

    return "\n".join(body), {k: "".join(v) for k, v in spoken.items()}, headers


def expand(pattern: str, value: float | int) -> list[str]:
    """{v} に「3桁区切りあり」「なし」の両方を入れた候補を返す。"""
    forms = {f"{value:,}", str(value)}
    return [pattern.replace("{v}", re.escape(f)) for f in forms]


def main() -> int:
    ice = load("athena_vs_s3tables.json")
    summ = load("summary.json")
    pref = load("prefecture_comparison.json")
    ren = load("rename_blindspot.json")
    now = load("akita_now.json")

    body, spoken, headers = split_script()

    pos = ice["athena_style_positional_read"]
    mis = pos["mislabeled_in_sample_row"]
    sanity = pos["sanity_check_total_equals_sum"]
    totals = ice["cross_era_query"]["respondent_total_by_year"]
    jump = round(100 * (totals["2019"] / totals["2018"] - 1), 1)
    nagasaki = next(x["header_row"] for x in pref["header_not_first_row"] if x["pref"] == "長崎県")

    # 冒頭と締めで出す「今の秋田」の数字(out/akita_now.json)
    age_last = now["age"]["last"]
    out_reasons = {d["reason"]: d for d in now["reasons"]["out"]["items"]}
    in_reasons = {d["reason"]: d for d in now["reasons"]["in"]["items"]}
    top_out = now["reasons"]["out"]["items"][0]

    # (説明, 値, 本文に出現すべき正規表現。{v} が値に置き換わる)
    #
    # 第1段(リネーム / out/rename_blindspot.json)と
    # 第2段(列削除 / out/athena_vs_s3tables.json)の両方を検査する。
    ren_over = {(o["era"], o["area"]): o for o in ren["overstatement"]}
    required: list[tuple[str, float | int, str]] = [
        # 導入
        ("1980年の人口", summ["population"]["first"], r"{v}"),
        ("2025年の人口", summ["population"]["last"], r"{v}"),
        ("人口の減少率", abs(summ["population"]["pct"]), r"{v}|30パーセント"),
        # 今の秋田(S2 で出して S11 で出し直す4つの数字)
        ("ピークの人口", now["population"]["peak"], r"{v}"),
        ("直近の月報人口", now["monthly_2026"]["last_population"], r"{v}"),
        ("65歳以上の割合", age_last["over65_pct"], r"{v}パーセント|{v}%"),
        ("75歳以上の人数", age_last["over75"], r"{v}人"),
        ("15歳未満の割合", age_last["under15_pct"], r"{v}パーセント|{v}%"),
        ("2025年の自然増減", abs(now["monthly_2025"]["natural"]), r"{v}人"),
        ("2025年の社会増減", abs(now["monthly_2025"]["social"]), r"{v}人"),
        ("自然減の割合", now["monthly_2025"]["natural_share_pct"], r"{v}パーセント|{v}%"),
        ("県外転出の総数", now["reasons"]["out"]["total"], r"{v}人"),
        ("転出理由1位の割合", round(top_out["pct"]), r"{v}パーセント|{v}%"),
        ("転入の退職・同居", in_reasons["退職・同居"]["people"], r"{v}人"),
        ("転出の退職・同居", out_reasons["退職・同居"]["people"], r"{v}人"),
        # 第1段: リネーム
        ("月報人口の列数", ren["columns"]["count_before"], r"{v}列"),
        ("改称された列数", ren["columns"]["renamed"], r"{v}列"),
        (
            "挿入・削除・並べ替えの件数",
            ren["columns"]["inserted_or_deleted_or_reordered"],
            r"{v}件|1件もありません",
        ),
        ("読めた行数", ren["hive_style_read"]["rows_read"], r"{v}行"),
        ("意味不変の検算行数", ren["semantics_unchanged"]["by_era"]["2020年版"]["passed"], r"{v}行"),
        ("市部計の誤った値", ren_over[("2020", "市部計")]["believed_kengai"], r"{v}人"),
        ("市部計の実際の県外", ren_over[("2020", "市部計")]["actual_kengai"], r"{v}人"),
        (
            "市部計の過大率",
            round(ren_over[("2020", "市部計")]["overstated_pct"]),
            r"{v}パーセント|{v}%",
        ),
        ("郡部計の誤った値", ren_over[("2020", "郡部計")]["believed_kengai"], r"{v}人"),
        ("郡部計の実際の県外", ren_over[("2020", "郡部計")]["actual_kengai"], r"{v}人"),
        (
            "郡部計の過大率",
            round(ren_over[("2020", "郡部計")]["overstated_pct"]),
            r"{v}パーセント|{v}%",
        ),
        # 第2段: 列削除
        ("旧版の列数", ice["versions"]["2013-2018_cols"], r"{v}列"),
        ("新版の列数", ice["versions"]["2019-2025_cols"], r"{v}列"),
        ("結婚・離婚の報告値", mis["結婚・離婚"]["reported"], r"{v}"),
        ("結婚・離婚の真値", mis["結婚・離婚"]["true_value_of_this_name"], r"{v}"),
        ("家業後継の報告値", mis["家業後継"]["reported"], r"{v}"),
        ("別項目を返す列数", pos["columns_returning_other_item"], r"{v}項目|{v}列"),
        ("NULL埋めの列数", pos["columns_null_padded"], r"{v}項目|{v}列"),
        ("検算した全行数", ice["iceberg"]["rows"], r"{v}行"),
        # Iceberg 側
        ("union_by_name 後の列数", ice["iceberg"]["columns_after_union_by_name"], r"{v}列|から{v}"),
        ("2018年の回答総数", totals["2018"], r"{v}"),
        ("2019年の回答総数", totals["2019"], r"{v}"),
        ("回答総数の増加率", jump, r"{v}|43パーセント"),
        # 規模
        ("CSV の実サイズKB", ice["plain_csv"]["total_kb"], r"{v} ?KB"),
        ("Iceberg の実サイズKB", ice["iceberg"]["total_kb"], r"{v} ?KB"),
        # 全国比較(Q&A用)
        ("調査ファイル数", pref["files"], r"{v}ファイル"),
        ("Shift_JIS のファイル数", pref["encodings"]["Shift_JIS"], r"{v}がShift_JIS|Shift_JIS {v}"),
        ("ヘッダが1行目にない県の数", len(pref["header_not_first_row"]), r"{v}件"),
        ("長崎のヘッダ行", nagasaki, r"{v}行目"),
    ]

    # 実行ごとに揺れる値。数値として近いかで見る。
    bench: list[tuple[str, float, str]] = [
        ("CSV の全件スキャン", ice["plain_csv"]["full_scan_ms_min"], r"([\d.]+) ?ms"),
        ("Iceberg の全件スキャン", ice["iceberg"]["full_scan_ms_min"], r"([\d.]+) ?ms"),
    ]

    # 別テーブル(月報人口)の実測値。本文に混ぜてはいけない。
    forbidden = ["12.4", "2.3ms", "2.3 ms"]

    failures: list[str] = []

    print("== 必須の数字 ==")
    for label, value, pattern in required:
        hit = next((p for p in expand(pattern, value) if re.search(p, body)), None)
        if hit:
            print(f"  ok   {label}: {value:,}")
        else:
            print(f"  FAIL {label}: {value:,} が本文に無い (期待パターン {pattern})")
            failures.append(f"必須の数字が本文に無い: {label} ({value:,})")

    print("\n== ベンチ値(±25%) ==")
    for label, value, pattern in bench:
        found = [float(x) for x in re.findall(pattern, body)]
        near = [f for f in found if abs(f - value) <= value * BENCH_TOLERANCE]
        if near:
            print(f"  ok   {label}: 実測 {value} / 本文 {near}")
        else:
            print(f"  FAIL {label}: 実測 {value} に近い値が本文に無い (本文の候補 {found})")
            failures.append(f"ベンチ値が乖離: {label} (実測 {value})")

    print("\n== 禁止の数字(別テーブルの実測値との混在) ==")
    for token in forbidden:
        if token in body:
            print(f"  FAIL '{token}' が本文にある")
            failures.append(f"別テーブルの数字が混ざっている: {token}")
        else:
            print(f"  ok   '{token}' は本文に無い")

    print("\n== 尺の整合(見出しの時刻 vs 話す文字数) ==")
    for key, header_secs in headers:
        calc = max(len(spoken[key]) / CPM * 60 * OVERHEAD, MIN_SLIDE_SECS)
        if abs(calc - header_secs) > TOLERANCE_SECS:
            print(f"  FAIL {key}: 見出し {header_secs}秒 / 再計算 {calc:.0f}秒")
            failures.append(f"見出しの秒数が文字数と合わない: {key}")
        else:
            print(f"  ok   {key}: {header_secs}秒")

    total_chars = sum(len(v) for v in spoken.values())
    total_secs = sum(max(len(v) / CPM * 60 * OVERHEAD, MIN_SLIDE_SECS) for v in spoken.values())
    print(
        f"\n  話す文字数 {total_chars:,}字 / 総尺 {int(total_secs) // 60}:{int(total_secs) % 60:02d}"
        f" / 15分枠の余裕 {int(900 - total_secs) // 60}:{int(900 - total_secs) % 60:02d}"
    )
    if total_secs > 900:
        failures.append(f"総尺が15分を超えている: {total_secs:.0f}秒")
    if any("見出しの秒数" in f for f in failures):
        print("  ヒント: uv run python scripts/retime_talk_script.py で見出しと尺表を再生成する")

    print("\n" + "=" * 60)
    if failures:
        print(f"NG: {len(failures)} 件")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(
        f"OK: 必須 {len(required)} 件 / ベンチ {len(bench)} 件 / "
        f"禁止 {len(forbidden)} 件 / 節 {len(headers)} 件 すべて一致"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
