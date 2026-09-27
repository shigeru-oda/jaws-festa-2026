"""JAWS FESTA 2026 in AKITA 登壇用 検証ノートブック(5)

登壇の冒頭と締めで使う「今の秋田」の数字を、同梱 CSV から機械的に出す。

ここで出す数字は本編の主張(列が変わると集計が静かに間違う)の**対象**になる。
S3+Athena の素の構成で出すと間違い、S3 Tables で出すと合う、その集計そのもの。
原稿に手で書いた数字が古くならないよう `out/akita_now.json` に落として
`scripts/check_talk_numbers.py` から突き合わせる。

実行:
    uv run marimo edit notebooks/akita_now.py   # 対話
    uv run python notebooks/akita_now.py        # スクリプトとして通す

出典: 秋田県オープンデータポータルサイト (https://opendata.pref.akita.lg.jp/)
      を加工して作成 / CC BY 4.0
"""

import marimo

__generated_with = "0.23.16"
app = marimo.App(width="medium")


@app.cell
def _():
    import csv
    import json
    from pathlib import Path

    import marimo as mo

    ROOT = Path(__file__).resolve().parent.parent
    DATA = ROOT / "data" / "akita"
    RIYU = ROOT / "data" / "akita_idouriyuu"
    OUT = ROOT / "out"
    OUT.mkdir(exist_ok=True)

    def rows(path):
        """UTF-8 BOM 付き CSV を (ヘッダ, 空行を除いた行) で返す。"""
        with open(path, encoding="utf-8-sig", newline="") as fh:
            reader = csv.reader(fh)
            header = next(reader)
            return header, [r for r in reader if any(r)]

    def num(cell):
        """欠測記号(*** など)と桁区切りを潰して float にする。読めなければ None。"""
        s = (cell or "").replace(",", "").strip()
        if s in ("", "-", "－", "―", "*", "***", "…"):
            return None
        try:
            return float(s)
        except ValueError:
            return None

    mo.md("## 今の秋田 — 同梱CSVから出す")
    return DATA, OUT, RIYU, json, mo, num, rows


@app.cell
def _(DATA, mo, num, rows):
    # 人口の年次推移(1980-2025)。ピークと最新を取る。
    _h, _r = rows(DATA / "pref_jinko_nenjisuii_1980-2025.csv")
    _i_date = _h.index("年月日")
    _i_pop = _h.index("総人口(人)")
    series = [(r[_i_date], num(r[_i_pop])) for r in _r if num(r[_i_pop]) is not None]
    peak = max(series, key=lambda t: t[1])
    latest_census = series[-1]

    population = {
        "peak_label": peak[0],
        "peak": int(peak[1]),
        "latest_label": latest_census[0],
        "latest": int(latest_census[1]),
        "lost_from_peak": int(peak[1] - latest_census[1]),
        "pct_from_peak": round((latest_census[1] / peak[1] - 1) * 100, 1),
    }
    mo.md(f"ピーク {population['peak_label']} {population['peak']:,}人 → "
          f"{population['latest_label']} {population['latest']:,}人 "
          f"({population['pct_from_peak']}%)")
    return (population,)


@app.cell
def _(DATA, mo, num, rows):
    # 月報人口。県計の行だけを見る。自然増減と社会増減の内訳が要点。
    def monthly(path):
        _h, _r = rows(path)
        ken = [r for r in _r if r[3] == "県計"]
        nat = [num(r[16]) for r in ken if num(r[16]) is not None]
        soc = [num(r[29]) for r in ken if num(r[29]) is not None]
        last = ken[-1]
        return {
            "months": len(ken),
            "last_label": last[1],
            "last_population": int(num(last[4])),
            "natural": int(sum(nat)),
            "social": int(sum(soc)),
            "natural_share_pct": round(sum(nat) / (sum(nat) + sum(soc)) * 100),
        }

    m2025 = monthly(DATA / "pref_jinkousetai_2025.csv")
    m2026 = monthly(DATA / "pref_jinkousetai_2026.csv")
    mo.md(
        f"2025年通年: 自然増減 {m2025['natural']:+,} / 社会増減 {m2025['social']:+,} "
        f"→ 減少の {m2025['natural_share_pct']}% が自然減 ／ "
        f"直近 {m2026['last_label']} {m2026['last_population']:,}人"
    )
    return m2025, m2026


@app.cell
def _(DATA, mo, num, rows):
    # 年齢3区分の時系列。県計・男女計の最初と最新を取る。
    _h, _r = rows(DATA / "pref_jikei_3_nenrei3kubun.csv")
    _ik, _im, _id = _h.index("県・市町村"), _h.index("男女別"), _h.index("年月日")
    _ken = [r for r in _r if r[_ik] == "県計" and r[_im] == "男女計"]

    def _pick(row):
        def g(name):
            return num(row[_h.index(name)])

        return {
            "label": row[_id],
            "total": int(g("人口・総数（人）")),
            "under15_pct": g("年齢別割合・15歳未満（％）"),
            "over65_pct": g("年齢別割合・65歳以上（％）"),
            "over75": int(g("人口・75歳以上（人）")),
        }

    age = {"first": _pick(_ken[0]), "last": _pick(_ken[-1]), "points": len(_ken)}
    mo.md(
        f"65歳以上 {age['first']['over65_pct']}% ({age['first']['label']}) → "
        f"{age['last']['over65_pct']}% ({age['last']['label']})、"
        f"15歳未満 {age['last']['under15_pct']}%、75歳以上 {age['last']['over75']:,}人"
    )
    return (age,)


@app.cell
def _(RIYU, mo, num, rows):
    # 移動理由。最新年度の県外転出・県外転入を、理由の構成比で並べる。
    _h, _r = rows(RIYU / "03_kaitousya_2019-2025.csv")
    _years = sorted({r[1] for r in _r})
    _last_year = _years[-1]

    def breakdown(kubun):
        sel = [
            r
            for r in _r
            if r[1] == _last_year and r[3] == kubun and r[5] == "男女計" and r[6] == "総数"
        ]
        if not sel:
            return None
        row = sel[0]
        total = num(row[7])
        items = [
            {
                "reason": _h[i].replace("（人）", ""),
                "people": int(num(row[i]) or 0),
                "pct": round((num(row[i]) or 0) / total * 100, 1),
            }
            for i in range(8, 16)
        ]
        items.sort(key=lambda d: -d["people"])
        return {"total": int(total), "items": items}

    reasons = {
        "year": _last_year,
        "out": breakdown("県外転出"),
        "in": breakdown("県外転入"),
    }
    mo.md(
        "転出 "
        + " / ".join(f"{d['reason']} {d['pct']}%" for d in reasons["out"]["items"][:3])
        + " ／ 転入 "
        + " / ".join(f"{d['reason']} {d['pct']}%" for d in reasons["in"]["items"][:3])
    )
    return (reasons,)


@app.cell
def _(OUT, age, json, m2025, m2026, population, reasons):
    akita_now = {
        "dataset": "秋田県 人口統計(年次推移 / 月報人口 / 年齢3区分 / 人口移動理由) / CC BY 4.0",
        "population": population,
        "monthly_2025": m2025,
        "monthly_2026": m2026,
        "age": age,
        "reasons": reasons,
    }
    (OUT / "akita_now.json").write_text(
        json.dumps(akita_now, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(akita_now, ensure_ascii=False, indent=2))
    return


if __name__ == "__main__":
    app.run()
