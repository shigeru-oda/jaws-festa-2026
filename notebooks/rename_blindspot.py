"""JAWS FESTA 2026 in AKITA 登壇用 検証ノートブック(3)

登壇の核心「CSV を S3 に置いて Athena で読む構成は、列名の変更に気づけない」を
AWS を使わずローカルで確定させる。

題材は秋田県の月報人口 CSV。**2024 年に 36 列中 26 列の列名が変わった**が、
列の並び順は 36 列すべて同一で、値の意味も変わっていない。変わったのはラベルだけ。

なぜ気づけないのか。Athena の CSV テーブルは `skip.header.line.count=1` で
**ヘッダ行を捨てる**ので、列名という文字列は S3 上のファイルに書かれているだけで
処理系には一度も渡らない。気づかないのではなく、気づく材料が届いていない。

ここでは Hive/Athena の CSV テーブル(固定スキーマ + 位置読み + 欠けた列は NULL)を
DuckDB の `read_csv(header=false, skip=1, columns=..., null_padding=true,
auto_detect=false)` で模擬する。

実行:
    uv run marimo edit notebooks/rename_blindspot.py   # 対話
    uv run python notebooks/rename_blindspot.py        # スクリプトとして通す

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
        # 列名のリネームに気づけない — ローカル再現

        確かめたいのは1点。**列名だけが変わったとき、置くだけ構成は何を返すのか。**

        | | 素の構成 (S3 + CSV + Athena) | S3 Tables (Iceberg) |
        |---|---|---|
        | 列の同定 | **位置**(LazySimpleSerDe) | **field ID** |
        | ヘッダ行 | **捨てる**(`skip.header.line.count=1`) | 取り込み時に列名として使う |
        | リネームの記録 | どこにも残らない | スキーマ進化として記録 |

        Athena のスキーマ更新の対応表は CSV について「列名の変更は可」としている。
        可というのは**壊れない**という意味で、**気づける**という意味ではない。

        <https://docs.aws.amazon.com/athena/latest/ug/handling-schema-updates-chapter.html>
        """
    )
    return (mo,)


@app.cell
def _():
    import csv
    from pathlib import Path

    import duckdb

    ROOT = Path(__file__).resolve().parent.parent
    DATA = ROOT / "data" / "akita"
    OUT = ROOT / "out"
    OUT.mkdir(exist_ok=True)

    F_OLD = DATA / "pref_jinkousetai_2020.csv"  # 改称前
    F_NEW = DATA / "pref_jinkousetai_2024.csv"  # 改称後

    def header_of(path):
        with open(path, encoding="utf-8-sig") as fh:
            return next(csv.reader(fh))

    H_OLD, H_NEW = header_of(F_OLD), header_of(F_NEW)
    con = duckdb.connect()
    return DATA, F_NEW, F_OLD, H_NEW, H_OLD, OUT, ROOT, con, csv, header_of


@app.cell
def _(H_NEW, H_OLD, mo):
    # 位置ごとに突き合わせる。ここが今回の要点。
    renamed = [
        (i + 1, a, b)
        for i, (a, b) in enumerate(zip(H_OLD, H_NEW))
        if a != b
    ]
    kept = [a for a, b in zip(H_OLD, H_NEW) if a == b]

    _rows = "\n".join(
        f"| {i} | `{a}` | `{b}` |"
        for i, a, b in renamed
        if i in (5, 8, 20, 21, 23, 25, 28, 30)
    )

    mo.md(
        f"""
        ## 並び順は変わっていない

        - 列数: **{len(H_OLD)} -> {len(H_NEW)}**(変化なし)
        - 名前が変わった列: **{len(renamed)}**
        - 名前が同じ列: **{len(kept)}**
        - **列の挿入・削除・並べ替えは1件もない**

        改称された列の抜粋(位置は同じまま):

        | 位置 | 2020年版 | 2024年版 |
        |---|---|---|
        {_rows}

        位置が同じなら、Athena は同じ値を返し続ける。**値は壊れない。**
        """
    )
    return kept, renamed


@app.cell
def _(F_NEW, F_OLD, H_NEW, H_OLD, con, mo):
    # Glue/Athena は列名にアンダースコア以外の特殊文字を許さない。日本語ヘッダは
    # そのまま列名にできないので、ここでは c01..c36 に固定する(ローマ字化と同じ扱い)。
    COLS = [f"c{_i:02d}" for _i in range(1, len(H_OLD) + 1)]
    LABEL_OLD = dict(zip(COLS, H_OLD))  # テーブル定義を作った時点の「人間の理解」
    LABEL_NEW = dict(zip(COLS, H_NEW))  # ファイル側の実際の意味

    _spec = ", ".join(f"'{_c}': 'VARCHAR'" for _c in COLS)

    def hive_read(path):
        """Hive/Athena の CSV テーブルと同じ読み方。

        - 固定スキーマ(columns=): カタログのテーブル定義に相当
        - header=false, skip=1: ヘッダ行を捨てて位置で読む
        - null_padding=true: 足りない列は NULL
        - auto_detect=false: DuckDB のスニファを止める。付けないと列数不一致を
          検出してエラーにする(Hive/Athena はこの検査をしない)
        """
        return (
            f"SELECT * FROM read_csv('{path}', header=false, skip=1, delim=',', "
            f"columns={{{_spec}}}, null_padding=true, auto_detect=false)"
        )

    con.execute(
        "CREATE OR REPLACE VIEW hive_jinkousetai AS "
        f"{hive_read(F_OLD)} UNION ALL BY NAME {hive_read(F_NEW)}"
    )
    hive_rows = con.execute("SELECT count(*) FROM hive_jinkousetai").fetchone()[0]

    mo.md(
        f"""
        ## 2020年版の定義で両年を読む

        テーブル定義は改称前(2020年版)の {len(COLS)} 列。同じ定義で 2024 年版も読む。

        結果は **{hive_rows} 行。エラーも警告もない。**
        """
    )
    return COLS, LABEL_NEW, LABEL_OLD, hive_read, hive_rows


@app.cell
def _(LABEL_NEW, LABEL_OLD, mo):
    # 転入系の3列に注目する。ここに問題が集約している。
    FOCUS = ["c20", "c23", "c24"]

    _rows = "\n".join(
        f"| `{_c}` | `{LABEL_OLD[_c]}` | `{LABEL_NEW[_c]}` | "
        f"{'★改称' if LABEL_OLD[_c] != LABEL_NEW[_c] else '同一'} |"
        for _c in FOCUS
    )

    mo.md(
        f"""
        ## 注目する3列

        | 列 | 定義(2020年版由来) | 2024年版の実ヘッダ | |
        |---|---|---|---|
        {_rows}

        `c20` は 2020 年版では `県外転入・男女計（人）` という名前だが、
        同じファイルの `c24` に `転入・県外計（人）`(県外のみ)が**別に存在する**。
        つまり 2020 年版の時点で **`c20` のラベルは実態と矛盾していた**。
        """
    )
    return (FOCUS,)


@app.cell
def _(con, mo):
    # c20 の中身は何なのか。c23(県内) + c24(県外) と一致するかで確かめる。
    identity = con.execute(
        """
        SELECT CASE WHEN CAST(substr(c01, 1, 4) AS INT) <= 2020
                    THEN '2020年版' ELSE '2024年版' END AS era,
               count(*) AS n_rows,
               sum(CASE WHEN TRY_CAST(c20 AS BIGINT)
                             = TRY_CAST(c23 AS BIGINT) + TRY_CAST(c24 AS BIGINT)
                        THEN 1 ELSE 0 END) AS n_ok
        FROM hive_jinkousetai
        GROUP BY 1 ORDER BY 1
        """
    ).fetchall()

    _tbl = "\n".join(f"| {_e} | {_n} | {_ok} |" for _e, _n, _ok in identity)

    mo.md(
        f"""
        ## `c20` は両年とも「県内＋県外の合計」

        | 版 | 行数 | `c20 == c23 + c24` が成立 |
        |---|---|---|
        {_tbl}

        差分は欠損記号 `***` の行。つまり **`c20` の意味は一度も変わっていない。**
        2024 年の改称は `転入・合計（人）` という**正しい名前への訂正**だった。
        """
    )
    return (identity,)


@app.cell
def _(con, mo):
    # 「県外転入」だと信じて集計すると、どれだけ間違うか
    overstate = con.execute(
        """
        SELECT substr(c01, 1, 4) AS era, c04 AS area,
               TRY_CAST(c20 AS BIGINT) AS believed_kengai,
               TRY_CAST(c23 AS BIGINT) AS kennai,
               TRY_CAST(c24 AS BIGINT) AS actual_kengai
        FROM hive_jinkousetai
        WHERE c04 IN ('市部計', '郡部計', '秋田市') AND c01 LIKE '%000101'
        ORDER BY era, area
        """
    ).fetchall()

    _rows = "\n".join(
        f"| {_e} | {_a} | **{_b:,}** | {_k:,} | {_c:,} | **+{(_b / _c - 1) * 100:.0f}%** |"
        for _e, _a, _b, _k, _c in overstate
        if _c
    )

    mo.md(
        f"""
        ## 「県外転入」として集計した場合の過大率

        | 年 | 区分 | 定義上の県外転入 | 県内転入 | 実際の県外(`c24`) | 過大率 |
        |---|---|---|---|---|---|
        {_rows}

        県内移動をまるごと県外扱いしている。**2020 年と 2024 年でほぼ同じだけ間違う**ので、
        訂正が入っても結果は変わらない。誤りは 2020 年から一貫している。
        """
    )
    return (overstate,)


@app.cell
def _(con, mo):
    # 年をまたぐ集計も完走する(エラーで止まらない)
    yearly = con.execute(
        """
        SELECT substr(c01, 1, 4) AS era,
               sum(TRY_CAST(c20 AS BIGINT)) AS believed_kengai,
               sum(TRY_CAST(c24 AS BIGINT)) AS actual_kengai
        FROM hive_jinkousetai
        WHERE c04 = '県計'
        GROUP BY 1 ORDER BY 1
        """
    ).fetchall()

    _tbl = "\n".join(f"| {_e} | {_b:,} | {_c:,} |" for _e, _b, _c in yearly)

    mo.md(
        f"""
        ## 年をまたぐ集計も通る

        | 年 | 定義上の「県外転入」の年計 | 実際の県外の年計 |
        |---|---|---|
        {_tbl}

        県計では県内転入が `***`(県内移動は県計で相殺されるため)なので、
        この粒度では両者が一致する。**市町村別に落とすと上表のようにずれる。**

        いずれにせよクエリは成功し、値も自然な大きさで返る。**止まる材料がない。**
        """
    )
    return (yearly,)


@app.cell
def _(mo):
    mo.md(
        """
        ## なぜ気づけないのか

        「Athena が位置で読むから名前の変化を無視する」よりも根本的な理由がある。

        **ヘッダ行はクエリに入っていない。** CSV テーブルは
        `skip.header.line.count=1` でヘッダ行を捨てるので、列名という文字列は
        S3 上のファイルに書かれているだけで、処理系には一度も渡らない。
        県が訂正情報をファイルの1行目に書いても、その行は捨てられる。

        さらに、この変更は

        - 列の位置が同じ
        - 値の意味も同じ(`c20` は両年とも合計)
        - 行数も型も同じ

        なので、**Athena 側に検出可能な変化が物理的に存在しない**。
        実装の不備ではなく、構造上そうなる。

        気づけるのは**テーブル定義を作り直したとき**だけ。Glue Crawler を再実行すれば
        列名は更新されるが、それは人間が能動的にやる操作で、データ側からは通知されない。

        > 補足: 再クロールは今回のケースでは無害(意味が変わっていないため)。
        > ただし**位置がずれる変更**(列の挿入・削除)だった場合、再クロールで
        > 新しい列名を割り当てると旧ファイルの値が別の列に流れ込む。
        > その実測は `notebooks/athena_vs_s3tables.py` にある(列削除で7列が誤り3列がNULL)。
        """
    )
    return


@app.cell
def _(OUT, mo, overstate):
    import altair as alt
    import polars as pl

    _recs = []
    for _e, _a, _b, _k, _c in overstate:
        if not _c:
            continue
        _recs.append({"区分": f"{_a} ({_e})", "系列": "「県外転入」として集計した値", "人数": _b})
        _recs.append({"区分": f"{_a} ({_e})", "系列": "実際の県外のみ", "人数": _c})

    _df = pl.DataFrame(_recs)
    _order = list(dict.fromkeys(_df["区分"].to_list()))

    _base = alt.Chart(
        _df, title="列名を信じて集計するとどれだけ過大になるか (秋田県 月報人口)"
    ).encode(
        y=alt.Y("区分:N", sort=_order, title=None),
        x=alt.X("人数:Q"),
        yOffset=alt.YOffset("系列:N", sort=["「県外転入」として集計した値", "実際の県外のみ"]),
    )
    chart_overstate = (
        _base.mark_bar().encode(
            color=alt.Color(
                "系列:N",
                sort=["「県外転入」として集計した値", "実際の県外のみ"],
                scale=alt.Scale(range=["#c0392b", "#2e5f8a"]),
            )
        )
        + _base.mark_text(align="left", dx=4, fontSize=11).encode(text="人数:Q")
    ).properties(width=620)

    chart_overstate.properties(config={"font": "Hiragino Sans"}).save(
        str(OUT / "rename_overstate.png"), ppi=144
    )

    mo.md("図を `out/rename_overstate.png` に書き出した。")
    return alt, chart_overstate, pl


@app.cell
def _(
    COLS,
    H_NEW,
    H_OLD,
    LABEL_NEW,
    LABEL_OLD,
    OUT,
    hive_rows,
    identity,
    kept,
    overstate,
    renamed,
    yearly,
):
    import json

    summary = {
        "dataset": "秋田県 月報人口(pref_jinkousetai) / CC BY 4.0",
        "files": {"before": "pref_jinkousetai_2020.csv", "after": "pref_jinkousetai_2024.csv"},
        "columns": {
            "count_before": len(H_OLD),
            "count_after": len(H_NEW),
            "renamed": len(renamed),
            "kept": len(kept),
            "inserted_or_deleted_or_reordered": 0,
            "renamed_detail": [
                {"position": _i, "before": _a, "after": _b} for _i, _a, _b in renamed
            ],
        },
        "hive_style_read": {
            "table_definition_from": "2020年版のヘッダ(36列)",
            "rows_read": hive_rows,
            "errors": 0,
            "note": "ヘッダ行は skip.header.line.count=1 相当で捨てられるため、列名は処理系に渡らない",
        },
        "focus_columns": {
            _c: {"definition_label": LABEL_OLD[_c], "actual_label_2024": LABEL_NEW[_c]}
            for _c in ("c20", "c23", "c24")
        },
        "semantics_unchanged": {
            "assertion": "c20 == c23 + c24 (c20 は両年とも県内+県外の合計)",
            "by_era": {_e: {"rows": _n, "passed": _ok} for _e, _n, _ok in identity},
        },
        "overstatement": [
            {
                "era": _e,
                "area": _a,
                "believed_kengai": _b,
                "kennai": _k,
                "actual_kengai": _c,
                "overstated_pct": round((_b / _c - 1) * 100, 1) if _c else None,
            }
            for _e, _a, _b, _k, _c in overstate
        ],
        "yearly_total": [
            {"era": _e, "believed_kengai": _b, "actual_kengai": _c} for _e, _b, _c in yearly
        ],
        "column_ids": COLS,
    }

    (OUT / "rename_blindspot.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary["columns"], ensure_ascii=False, indent=2)[:400])
    print(json.dumps(summary["semantics_unchanged"], ensure_ascii=False, indent=2))
    print(json.dumps(summary["overstatement"], ensure_ascii=False, indent=2))
    return json, summary


if __name__ == "__main__":
    app.run()
