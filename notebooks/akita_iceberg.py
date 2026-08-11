"""JAWS FESTA 2026 in AKITA 登壇用 検証ノートブック

秋田県オープンデータ + DuckDB + Apache Iceberg(ローカル SQLite カタログ)で
S3 Tables 本番検証の前段を確認する。

実行:
    uv run marimo edit notebooks/akita_iceberg.py   # 対話
    uv run python notebooks/akita_iceberg.py        # スクリプトとして通す

出典: 秋田県オープンデータポータルサイト (https://opendata.pref.akita.lg.jp/)
      を加工して作成 / CC BY 4.0
"""

import marimo

__generated_with = "0.17"
app = marimo.App(width="medium")


@app.cell
def _():
    import marimo as mo

    mo.md(
        """
        # 秋田のオープンデータを Iceberg で扱う — 事前検証

        目的は3つ。

        1. 秋田県のオープンデータが**実際にどれだけ汚れているか**を掴む
        2. **スキーマ進化**と**タイムトラベル**を本物の Iceberg テーブルで再現する
        3. 同じコードが S3 Tables でそのまま動く形にしておく

        ここではカタログをローカル SQLite にしている。
        本番では `load_catalog` の設定を S3 Tables の REST エンドポイントへ
        差し替えるだけで済む。
        """
    )
    return (mo,)


@app.cell
def _():
    from pathlib import Path

    import duckdb

    ROOT = Path(__file__).resolve().parent.parent
    DATA = ROOT / "data" / "akita"
    WORK = ROOT / "work"
    WORK.mkdir(exist_ok=True)

    con = duckdb.connect()
    print("duckdb", duckdb.__version__)
    print("data files:", len(list(DATA.glob("*.csv"))))
    return DATA, Path, ROOT, WORK, con, duckdb


@app.cell
def _(DATA, WORK, mo):
    # つまずき その1: 文字コードが混在している。
    # DuckDB の read_csv は Shift_JIS を読めないので事前に UTF-8 へ寄せる。
    import subprocess

    SJIS_FILES = ["pref_jikei_1_syuyou_jinkou.csv", "pref_jyukidaicho_r5.csv"]
    CONVERTED = WORK / "utf8"
    CONVERTED.mkdir(exist_ok=True)

    converted = []
    for name in SJIS_FILES:
        src = DATA / name
        dst = CONVERTED / name
        if src.exists() and not dst.exists():
            subprocess.run(
                ["iconv", "-f", "SHIFT_JIS", "-t", "UTF-8", str(src)],
                stdout=dst.open("wb"),
                check=True,
            )
        converted.append(dst.name)

    mo.md(f"Shift_JIS → UTF-8 変換: `{'`, `'.join(converted)}`")
    return CONVERTED, converted, subprocess


@app.cell
def _(DATA, con, mo):
    # つまずき その2: 欠損が "-" "－" "***" で表現され、素直に型推論できない。
    # 一旦すべて VARCHAR で読み、TRY_CAST で落とす方針にする。
    trend = con.execute(
        f"""
        SELECT
            TRY_CAST(SUBSTR("年月日コード", 1, 4) AS INTEGER) AS year,
            TRY_CAST("総人口(人)" AS BIGINT)                  AS population,
            TRY_CAST("出生者数・合計（人）" AS BIGINT)          AS births,
            TRY_CAST("死亡者数・合計（人）" AS BIGINT)          AS deaths,
            TRY_CAST("自然増減数・合計（人）" AS BIGINT)        AS natural_change,
            TRY_CAST("社会増減数・合計（人）" AS BIGINT)        AS social_change
        FROM read_csv('{DATA / "pref_jinko_nenjisuii_1980-2025.csv"}', all_varchar=true)
        WHERE year IS NOT NULL
        ORDER BY year
        """
    ).pl()

    mo.md(
        f"""
        ## 秋田県の総人口 1980-2025

        - 行数: **{len(trend)}**
        - 1980年: **{trend['population'][0]:,} 人**
        - 最新年: **{trend['population'][-1]:,} 人**
        - 減少: **{trend['population'][0] - trend['population'][-1]:,} 人**
          ({(trend['population'][-1] / trend['population'][0] - 1) * 100:.1f}%)
        """
    )
    return (trend,)


@app.cell
def _(trend):
    import altair as alt

    pop_chart = (
        alt.Chart(trend)
        .mark_area(line={"color": "#c0392b"}, opacity=0.25, color="#c0392b")
        .encode(
            x=alt.X("year:O", title="年", axis=alt.Axis(values=list(range(1980, 2026, 5)))),
            y=alt.Y("population:Q", title="総人口(人)", scale=alt.Scale(zero=False)),
            tooltip=["year", "population"],
        )
        .properties(width=680, height=260, title="秋田県 総人口の推移 1980-2025")
    )
    pop_chart
    return alt, pop_chart


@app.cell
def _(alt, trend):
    # 自然増減(出生-死亡)と社会増減(転入-転出)を分けて見る。
    # 「なぜ減るのか」が一目で分かるのでスライドに使いやすい。
    import polars as pl

    label = {"natural_change": "自然増減(出生-死亡)", "social_change": "社会増減(転入-転出)"}
    long = (
        trend.unpivot(
            index="year",
            on=["natural_change", "social_change"],
            variable_name="kind",
            value_name="delta",
        )
        .drop_nulls("delta")
        .with_columns(pl.col("kind").replace(label))
    )

    change_chart = (
        alt.Chart(long)
        .mark_line(point=False)
        .encode(
            x=alt.X("year:O", title="年", axis=alt.Axis(values=list(range(1980, 2026, 5)))),
            y=alt.Y("delta:Q", title="増減(人)"),
            color=alt.Color("kind:N", title=None),
            tooltip=["year", "kind", "delta"],
        )
        .properties(width=680, height=240, title="人口増減の内訳")
    )
    change_chart
    return change_chart, label, long, pl


@app.cell
def _(DATA, con, mo):
    # 高齢化率の市町村ランキング(最新年、男女計)
    aging = con.execute(
        f"""
        WITH src AS (
            SELECT
                TRY_CAST(SUBSTR("年月日コード", 1, 4) AS INTEGER)     AS year,
                "県・市町村"                                          AS municipality,
                TRY_CAST("人口・総数（人）" AS BIGINT)                AS pop_total,
                TRY_CAST("年齢別割合・65歳以上（％）" AS DOUBLE)      AS ratio_65,
                TRY_CAST("年齢別割合・15歳未満（％）" AS DOUBLE)      AS ratio_u15
            FROM read_csv('{DATA / "pref_jikei_3_nenrei3kubun.csv"}', all_varchar=true)
            WHERE "男女別" = '男女計'
        )
        SELECT * FROM src
        WHERE year = (SELECT MAX(year) FROM src) AND municipality <> '県計'
        ORDER BY ratio_65 DESC
        """
    ).pl()

    mo.md(
        f"""
        ## 高齢化率ランキング({aging['year'][0]}年 / 男女計)

        最高: **{aging['municipality'][0]}** {aging['ratio_65'][0]:.1f}% ・
        最低: **{aging['municipality'][-1]}** {aging['ratio_65'][-1]:.1f}%
        """
    )
    return (aging,)


@app.cell
def _(aging, alt):
    aging_chart = (
        alt.Chart(aging)
        .mark_bar(color="#2c3e50")
        .encode(
            x=alt.X("ratio_65:Q", title="65歳以上の割合(%)"),
            y=alt.Y("municipality:N", sort="-x", title=None),
            tooltip=["municipality", "ratio_65", "ratio_u15", "pop_total"],
        )
        .properties(width=560, height=520, title="秋田県 市町村別 高齢化率")
    )
    aging_chart
    return (aging_chart,)


@app.cell
def _(DATA, con, mo):
    # ここが本題。同じデータセットなのに年度版でスキーマが違う。
    def columns_of(path):
        rel = con.execute(
            f"SELECT * FROM read_csv('{path}', all_varchar=true) LIMIT 0"
        )
        return list(rel.pl().columns)

    cols_2020 = columns_of(DATA / "pref_jinkousetai_2020.csv")
    cols_2025 = columns_of(DATA / "pref_jinkousetai_2025.csv")

    only_2020 = [c for c in cols_2020 if c not in cols_2025]
    only_2025 = [c for c in cols_2025 if c not in cols_2020]

    mo.md(
        f"""
        ## スキーマ進化の実例 1 — 列の改称と再編

        `pref_jinkousetai`(月報 人口・世帯数)は 2020年版と2025年版で列構成が変わる。

        - 2020年版のみ ({len(only_2020)}列): {", ".join(f"`{c}`" for c in only_2020)}
        - 2025年版のみ ({len(only_2025)}列): {", ".join(f"`{c}`" for c in only_2025)}

        列数は {len(cols_2020)} → {len(cols_2025)}。
        `人口・男女計（人）` が `人口・総数（人）` に改称され、
        転入/転出の区分も `県外/県内` から `合計/男計/女計/県内計/県外計` へ再編されている。
        """
    )
    return cols_2020, cols_2025, columns_of, only_2020, only_2025


@app.cell
def _(DATA, columns_of, mo):
    # 実例2: 列そのものが消える(2020年国勢調査で「年齢不詳」が消滅)
    kakusai = {}
    for y in (2000, 2005, 2010, 2015, 2020):
        p = DATA / f"pref_nenreikakusai_{y}.csv"
        if p.exists():
            cs = columns_of(p)
            kakusai[y] = cs

    rows = "\n".join(
        f"| {y} | {len(cs)} | {'あり' if any('年齢不詳' in c for c in cs) else '**なし**'} |"
        for y, cs in kakusai.items()
    )

    mo.md(
        f"""
        ## スキーマ進化の実例 2 — 列の削除

        | 年 | 列数 | `年齢不詳`列 |
        |---|---|---|
        {rows}

        2020年版で `年齢不詳` が落ちている。Iceberg の drop column に相当する変化が
        現実の公開データで起きている。
        """
    )
    return kakusai, p, rows


@app.cell
def _(ROOT, mo):
    # 本物の Iceberg テーブルを作る。カタログはローカル SQLite。
    # S3 Tables 本番では load_catalog の引数を REST エンドポイントに差し替える。
    import shutil

    from pyiceberg.catalog.sql import SqlCatalog

    WAREHOUSE = ROOT / "work" / "warehouse"
    if WAREHOUSE.exists():
        shutil.rmtree(WAREHOUSE)
    WAREHOUSE.mkdir(parents=True)

    catalog = SqlCatalog(
        "local",
        **{
            "uri": f"sqlite:///{WAREHOUSE / 'catalog.db'}",
            "warehouse": f"file://{WAREHOUSE}",
        },
    )
    catalog.create_namespace_if_not_exists("akita")

    mo.md(
        f"""
        ## ローカル Iceberg カタログ

        - warehouse: `{WAREHOUSE}`
        - namespace: `akita`

        S3 Tables に向けるときはここを REST カタログに差し替える。

        ```python
        catalog = load_catalog("s3tables", **{{
            "type": "rest",
            "uri": "https://glue.<region>.amazonaws.com/iceberg",
            "rest.sigv4-enabled": "true",
        }})
        ```
        """
    )
    return WAREHOUSE, SqlCatalog, catalog, shutil


@app.cell
def _(DATA, catalog, con, mo):
    # v1: 2020年版スキーマで作成
    import pyarrow as pa

    def load_arrow(path, cols):
        sel = ", ".join(f'"{c}"' for c in cols)
        return con.execute(
            f"SELECT {sel} FROM read_csv('{path}', all_varchar=true)"
        ).to_arrow_table()

    def align_to(tbl, schema):
        """進化後のスキーマに合わせて列順を揃え、無い列は NULL で埋める。"""
        arrays = []
        for field in schema:
            if field.name in tbl.schema.names:
                arrays.append(tbl.column(field.name))
            else:
                arrays.append(pa.nulls(tbl.num_rows, type=field.type))
        return pa.Table.from_arrays(arrays, schema=schema)

    BASE = ["年月日コード", "年月日", "区分コード", "区分"]
    V1 = BASE + ["人口・男女計（人）", "世帯数（世帯）"]

    t1 = load_arrow(DATA / "pref_jinkousetai_2020.csv", V1)
    table = catalog.create_table("akita.jinkousetai", schema=t1.schema)
    table.append(t1)

    mo.md(
        f"""
        ### v1 — 2020年版を投入

        - 行数: **{len(t1)}**
        - 列: {", ".join(f"`{c}`" for c in t1.schema.names)}
        - snapshot 数: **{len(table.history())}**
        """
    )
    return BASE, V1, align_to, load_arrow, pa, t1, table


@app.cell
def _(DATA, align_to, load_arrow, mo, table):
    # v2: 改称後の列名で追記する。union_by_name で新列を受け止める。
    V2 = [
        "年月日コード",
        "年月日",
        "区分コード",
        "区分",
        "人口・総数（人）",
        "世帯数（世帯）",
    ]
    t2 = load_arrow(DATA / "pref_jinkousetai_2025.csv", V2)

    with table.update_schema(allow_incompatible_changes=False) as us:
        us.union_by_name(t2.schema)

    table.append(align_to(t2, table.schema().as_arrow()))

    mo.md(
        f"""
        ### v2 — 2025年版を追記(スキーマ進化)

        - 追記行数: **{len(t2)}**
        - 進化後の列: {", ".join(f"`{f.name}`" for f in table.schema().fields)}
        - snapshot 数: **{len(table.history())}**

        `union_by_name` で新しい列 `人口・総数（人）` が足された。
        既存行はその列が NULL のまま保たれ、読み込みは壊れない。
        """
    )
    return V2, t2, us


@app.cell
def _(mo, table):
    # タイムトラベル: 各 snapshot で行数と列の埋まり方を比べる
    hist = table.history()
    lines = []
    for i, h in enumerate(hist, start=1):
        scan = table.scan(snapshot_id=h.snapshot_id).to_arrow()
        filled = {
            name: scan.column(name).null_count
            for name in ("人口・男女計（人）", "人口・総数（人）")
            if name in scan.schema.names
        }
        lines.append(
            f"| v{i} | `{h.snapshot_id}` | {scan.num_rows} | "
            + ", ".join(f"{k}: null {v}" for k, v in filled.items())
            + " |"
        )

    mo.md(
        f"""
        ## タイムトラベル

        | 版 | snapshot_id | 行数 | 列の埋まり方 |
        |---|---|---|---|
        {chr(10).join(lines)}

        `table.scan(snapshot_id=...)` で過去断面をそのまま読み直せる。
        年度版が更新されても前の版の集計を再現できる、というのが
        自治体データを扱ううえで一番効く性質だった。
        """
    )
    return filled, h, hist, i, lines, scan


@app.cell
def _(WAREHOUSE, mo, table):
    # 「小さいデータでは速度のうまみが出ない」を数字で確かめる
    import time

    def bench(fn, n=5):
        ts = []
        for _ in range(n):
            t0 = time.perf_counter()
            fn()
            ts.append((time.perf_counter() - t0) * 1000)
        return min(ts), sum(ts) / len(ts)

    ice_min, ice_avg = bench(lambda: table.scan().to_arrow())

    files = list((WAREHOUSE / "akita" / "jinkousetai" / "data").rglob("*.parquet"))
    total_bytes = sum(f.stat().st_size for f in files)

    mo.md(
        f"""
        ## サイズと所要時間

        - データファイル数: **{len(files)}** / 合計 **{total_bytes / 1024:.0f} KB**
        - 全件スキャン: 最速 **{ice_min:.1f} ms** / 平均 **{ice_avg:.1f} ms**

        この規模ではコンパクションの対象になるほどのファイル数にならない。
        S3 Tables の自動コンパクションや「クエリ最大3倍」が効いてくるのは
        もっと大きい領域で、そこは NOAA GHCN-Daily のような
        実スケールのデータで別途確かめる。
        """
    )
    return bench, files, ice_avg, ice_min, time, total_bytes


@app.cell
def _(mo):
    mo.md(
        """
        ## まとめ(登壇で言うこと)

        - 数MBの自治体データでは、S3 Tables の**速度面のうまみはほぼ出ない**
        - 効いたのは **スキーマ進化**・**タイムトラベル**・**横断クエリ**の3つ
        - 現実のつまずきは Iceberg 以前にある: **文字コード混在**、
          **欠損が `-` / `***`**、**表計算体裁の CSV**
        - ここまでの検証は全部ローカル。S3 Tables ではカタログ設定だけを差し替える
        """
    )
    return


@app.cell
def _(
    ROOT,
    aging,
    aging_chart,
    change_chart,
    cols_2020,
    cols_2025,
    files,
    hist,
    ice_avg,
    ice_min,
    kakusai,
    only_2020,
    only_2025,
    pop_chart,
    total_bytes,
    trend,
):
    # 検証結果を機械可読で残す。スライド作成時にここから数字を拾う。
    import json

    OUT = ROOT / "out"
    OUT.mkdir(exist_ok=True)

    for _name, _chart in (
        ("population_trend", pop_chart),
        ("population_change", change_chart),
        ("aging_ratio", aging_chart),
    ):
        _chart.properties(
            config={"font": "Hiragino Sans"}
        ).save(str(OUT / f"{_name}.png"), ppi=144)

    summary = {
        "population": {
            "first_year": int(trend["year"][0]),
            "first": int(trend["population"][0]),
            "last_year": int(trend["year"][-1]),
            "last": int(trend["population"][-1]),
            "lost": int(trend["population"][0] - trend["population"][-1]),
            "pct": round((trend["population"][-1] / trend["population"][0] - 1) * 100, 1),
        },
        "aging_top": [
            {"municipality": m, "ratio_65": r}
            for m, r in zip(aging["municipality"][:5], aging["ratio_65"][:5])
        ],
        "schema_evolution": {
            "jinkousetai_cols_2020": len(cols_2020),
            "jinkousetai_cols_2025": len(cols_2025),
            "only_2020": only_2020,
            "only_2025": only_2025,
            "nenreikakusai_age_unknown": {
                str(y): any("年齢不詳" in c for c in cs) for y, cs in kakusai.items()
            },
        },
        "iceberg": {
            "snapshots": len(hist),
            "data_files": len(files),
            "total_kb": round(total_bytes / 1024, 1),
            "full_scan_ms_min": round(ice_min, 1),
            "full_scan_ms_avg": round(ice_avg, 1),
        },
    }

    (OUT / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return OUT, json, summary


if __name__ == "__main__":
    app.run()
