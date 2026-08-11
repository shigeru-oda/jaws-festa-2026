"""JAWS FESTA 2026 in AKITA 登壇用 — 都道府県横断のスキーマ比較

JAWS-UG の支部がある39都道府県が公開する「市町村別人口」を集め、
文字コード・列構成・ヘッダ位置がどれだけ揃っていないかを実測する。
最後に、揃っていないスキーマを Iceberg の union_by_name で
1つのテーブルに束ねられることを確認する。

実行:
    uv run marimo edit notebooks/prefecture_schemas.py
    uv run python notebooks/prefecture_schemas.py

出典: 各都道府県のオープンデータポータル。ライセンスは県ごとに異なる
      (CC BY 4.0 / CC BY 2.1 日本 / Public Data License 1.0 / 政府標準利用規約系)。
      詳細は data/prefectures/_survey.json を参照。
"""

import marimo

__generated_with = "0.17"
app = marimo.App(width="medium")


@app.cell
def _():
    import marimo as mo

    mo.md(
        """
        # 同じ「市町村別人口」を39都道府県から集めたら

        JAWS-UG の支部は43あり、43支部は39都道府県に散っている。
        その39都道府県が公開する「市町村別人口」を集めてみると、
        統計の名前は同じなのに中身の作りが揃っていない。

        ここでは実際に取得できたCSVから、文字コード・列数・ヘッダ位置を
        **推測せず実測**する。
        """
    )
    return (mo,)


@app.cell
def _():
    import json
    from pathlib import Path

    ROOT = Path(__file__).resolve().parent.parent
    PREF_DIR = ROOT / "data" / "prefectures"
    OUT = ROOT / "out"
    OUT.mkdir(exist_ok=True)

    SURVEY = json.loads((PREF_DIR / "_survey.json").read_text(encoding="utf-8"))

    # ファイル名(ローマ字) → 都道府県名
    PREF_OF_FILE = {
        "aichi": "愛知県",
        "aomori": "青森県",
        "ehime": "愛媛県",
        "hokkaido": "北海道",
        "kagawa": "香川県",
        "kagoshima": "鹿児島県",
        "kanagawa": "神奈川県",
        "kyoto": "京都府",
        "miyagi": "宮城県",
        "nagasaki": "長崎県",
        "niigata": "新潟県",
        "niigata_japanese": "新潟県(日本人)",
        "oita": "大分県",
        "okinawa": "沖縄県",
        "saga": "佐賀県",
        "shizuoka": "静岡県",
        "tochigi": "栃木県",
        "tokushima": "徳島県",
        "tokyo": "東京都",
    }

    # 対応表の漏れは黙って通さない(ローマ字のままJSONに載って集計に混ざるため)
    _unmapped = sorted(
        p.stem.replace("_population", "")
        for p in PREF_DIR.glob("*_population.csv")
        if p.stem.replace("_population", "") not in PREF_OF_FILE
    )
    assert not _unmapped, f"PREF_OF_FILE に未登録のファイルがある: {_unmapped}"
    print("survey:", SURVEY["_meta"]["surveyed"], "都道府県")
    print("csv files:", len(list(PREF_DIR.glob("*_population.csv"))))
    return OUT, PREF_DIR, PREF_OF_FILE, Path, ROOT, SURVEY, json


@app.cell
def _(PREF_DIR, PREF_OF_FILE, mo):
    import csv
    import io

    import polars as pl

    def sniff(path):
        """BOM → UTF-8 → CP932 の順で判定する。推測ではなく実際に復号して決める。"""
        raw = path.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            return "UTF-8 (BOM)"
        try:
            raw.decode("utf-8")
            return "UTF-8"
        except UnicodeDecodeError:
            return "Shift_JIS"

    ENC_TO_PY = {"UTF-8 (BOM)": "utf-8-sig", "UTF-8": "utf-8", "Shift_JIS": "cp932"}

    def read_rows(path, enc_label):
        txt = path.read_text(encoding=ENC_TO_PY[enc_label], errors="replace")
        return list(csv.reader(io.StringIO(txt)))

    def header_row_index(rows):
        """ヘッダらしい行を探す。空セル率が低く、値が全部埋まっている最初の行。"""
        for i, r in enumerate(rows[:8]):
            filled = [c for c in r if c.strip()]
            if len(filled) >= 3 and len(filled) / max(len(r), 1) >= 0.7:
                return i
        return 0

    records = []
    for _path in sorted(PREF_DIR.glob("*_population.csv")):
        _key = _path.stem.replace("_population", "")
        _enc = sniff(_path)
        _rows = read_rows(_path, _enc)
        _hi = header_row_index(_rows)
        _header = _rows[_hi]
        _filled = [c for c in _header if c.strip()]
        records.append(
            {
                "pref": PREF_OF_FILE[_key],
                "file": _path.name,
                "encoding": _enc,
                "rows": len(_rows),
                "bytes": _path.stat().st_size,
                "header_row": _hi + 1,
                "n_columns": len(_header),
                "n_named": len(_filled),
                "header": ",".join(_header),
            }
        )

    schemas = pl.DataFrame(records).sort("n_columns")
    mo.md(
        f"""
        ## 取得できた{len(schemas)}ファイルの実測値

        ヘッダ行の位置も推測せず、「値が7割以上埋まっている最初の行」を
        ヘッダとして機械的に探した。
        """
    )
    return (
        ENC_TO_PY,
        csv,
        header_row_index,
        io,
        pl,
        read_rows,
        records,
        schemas,
        sniff,
    )


@app.cell
def _(mo, schemas):
    mo.ui.table(
        schemas.select("pref", "encoding", "n_columns", "n_named", "header_row", "rows", "bytes"),
        selection=None,
    )
    return


@app.cell
def _(mo, schemas):
    # 文字コードと列数のばらつきを数字で押さえる
    _enc = schemas.group_by("encoding").len().sort("len", descending=True)
    _late = schemas.filter(schemas["header_row"] > 1)
    _cmin, _cmax = schemas["n_columns"].min(), schemas["n_columns"].max()

    mo.md(
        f"""
        ### 数字で見ると

        - 文字コード: {" / ".join(f"**{r['encoding']}** {r['len']}件" for r in _enc.to_dicts())}
        - 列数: **{_cmin}〜{_cmax}列**（{_cmax / _cmin:.0f}倍の開き）
        - ヘッダが1行目にないファイル: **{len(_late)}件**
          （{", ".join(f"{r['pref']}: {r['header_row']}行目" for r in _late.to_dicts())}）

        列数は「多い方が親切」という話ではない。沖縄・愛媛が45列前後あるのは
        5歳階級を横に展開しているから、大分が6列なのは総数と男女だけだから。
        同じ問いに答えるための形が揃っていない。
        """
    )
    return


@app.cell
def _(alt_ready, schemas):
    import altair as alt

    col_chart = (
        alt.Chart(schemas)
        .mark_bar()
        .encode(
            x=alt.X("n_columns:Q", title="列数"),
            y=alt.Y("pref:N", sort="x", title=None),
            color=alt.Color(
                "encoding:N",
                title="文字コード",
                scale=alt.Scale(
                    domain=["UTF-8 (BOM)", "UTF-8", "Shift_JIS"],
                    range=["#2980b9", "#27ae60", "#c0392b"],
                ),
            ),
            tooltip=["pref", "n_columns", "encoding", "header_row", "rows"],
        )
        .properties(width=560, height=440, title="同じ「市町村別人口」の列数と文字コード")
    )
    col_chart
    return alt, col_chart


@app.cell
def _(SURVEY, mo, pl):
    # 39都道府県のうち、そもそもCSVを出しているのは何県か
    def csv_state(v):
        if v == "yes":
            return "CSV あり"
        if v == "no":
            return "Excel / PDF のみ"
        return "未確定・取得失敗"

    def platform_class(p):
        pl_ = p["platform"] or "ポータルなし・未整備"
        if "BODIK" in pl_:
            return "CKAN (BODIK 共同基盤)"
        if p["is_ckan"]:
            return "CKAN (独自運用)"
        if "なし" in pl_ or "未整備" in pl_:
            return "ポータルなし・未整備"
        return "非CKAN (独自基盤)"

    survey_df = pl.DataFrame(
        [
            {
                "pref": p["pref"],
                "region": p["region"],
                "csv": csv_state(p["csv"]),
                "platform": platform_class(p),
                "license": p["license"] or "不明",
            }
            for p in SURVEY["prefectures"]
        ]
    )

    _csv = survey_df.group_by("csv").len().sort("len", descending=True)
    _plat = survey_df.group_by("platform").len().sort("len", descending=True)

    mo.md(
        f"""
        ## その前の話 — CSVを出していない県が多い

        | 公開形式 | 県数 |
        |---|---|
        {chr(10).join(f"| {r['csv']} | {r['len']} |" for r in _csv.to_dicts())}

        | 基盤 | 県数 |
        |---|---|
        {chr(10).join(f"| {r['platform']} | {r['len']} |" for r in _plat.to_dicts())}

        列名の違いを議論する前に、**機械可読なデータが存在しない県のほうが多い**。
        CKANも少数派で、最大勢力は九州発の共同基盤 BODIK だった。
        """
    )
    return csv_state, platform_class, survey_df


@app.cell
def _(alt, survey_df):
    platform_chart = (
        alt.Chart(survey_df)
        .mark_bar()
        .encode(
            x=alt.X("count()", title="県数"),
            y=alt.Y("platform:N", sort="-x", title=None),
            color=alt.Color(
                "csv:N",
                title="人口CSV",
                scale=alt.Scale(
                    domain=["CSV あり", "Excel / PDF のみ", "未確定・取得失敗"],
                    range=["#27ae60", "#c0392b", "#95a5a6"],
                ),
            ),
            tooltip=["platform", "csv", "count()"],
        )
        .properties(width=560, height=200, title="39都道府県のポータル基盤と人口CSVの有無")
    )
    platform_chart
    return (platform_chart,)


@app.cell
def _(mo, schemas):
    # 「総数」列を持っているか。栃木は男+女を自分で足す必要がある。
    def has_total(header):
        cols = header.split(",")
        return any(("総数" in c or "総人口" in c or "人口計" in c or "人口総数" in c) for c in cols)

    _no_total = [r["pref"] for r in schemas.to_dicts() if not has_total(r["header"])]

    mo.md(
        f"""
        ## 列名の非直交 — 合計が無い県がある

        取得できたファイルのうち、総数にあたる列を持たないのは
        **{", ".join(_no_total)}**。
        栃木は `男(人)` と `女(人)` を自分で足さないと人口が出ない。

        単位の扱いも揃っていない。

        | 県 | 総数にあたる列名 |
        |---|---|
        | 大分県 | `人口総数` |
        | 神奈川県 | `人口総数` |
        | 沖縄県 | `総人口` |
        | 鹿児島県 | `人口計（人）` |
        | 青森県 | `総数(人)` ← 半角括弧 |
        | 東京都 | `人口総数（日本人＋外国人）` |
        | 栃木県 | **なし** |

        `（人）`が付く県と付かない県、全角括弧と半角括弧、
        日本人と外国人を分けるかどうか。単純な UNION では繋がらない。
        """
    )
    return (has_total,)


@app.cell
def _(mo):
    mo.md(
        """
        ## Iceberg で束ねる

        揃っていないスキーマを、`union_by_name` で1つのテーブルに積んでいく。
        県ごとに前処理を書き分けて同じ形に整えるのではなく、
        **違うまま入れて、後から必要な列だけ引く**。
        """
    )
    return


@app.cell
def _(PREF_DIR, ROOT, mo):
    import shutil

    from pyiceberg.catalog.sql import SqlCatalog

    PREF_WH = ROOT / "work" / "warehouse_pref"
    if PREF_WH.exists():
        shutil.rmtree(PREF_WH)
    PREF_WH.mkdir(parents=True)

    pref_catalog = SqlCatalog(
        "pref",
        **{
            "uri": f"sqlite:///{PREF_WH / 'catalog.db'}",
            "warehouse": f"file://{PREF_WH}",
        },
    )
    pref_catalog.create_namespace_if_not_exists("jp")

    mo.md(f"warehouse: `{PREF_WH}` / namespace `jp`")
    return PREF_WH, SqlCatalog, pref_catalog, shutil


@app.cell
def _(ENC_TO_PY, PREF_DIR, mo, pref_catalog, sniff):
    import duckdb
    import pyarrow as pa

    pref_con = duckdb.connect()

    # 単一ヘッダ行を持ち、市町村粒度の4県を選ぶ。
    # 列構成は 6 / 10 / 13 / 45 列でバラバラ。
    TARGETS = [
        ("大分県", "oita_population.csv"),
        ("神奈川県", "kanagawa_population.csv"),
        ("栃木県", "tochigi_population.csv"),
        ("沖縄県", "okinawa_population.csv"),
    ]

    def load_pref(path, enc_label):
        """全列VARCHARで読む。県ごとの型推論の差を持ち込まないため。

        DuckDB の read_csv は Shift_JIS を読めないので、
        Python 側で復号して UTF-8 に正規化したものを読ませる。
        """
        norm_dir = path.parent.parent.parent / "work" / "utf8_pref"
        norm_dir.mkdir(parents=True, exist_ok=True)
        norm = norm_dir / path.name
        if not norm.exists():
            norm.write_text(
                path.read_text(encoding=ENC_TO_PY[enc_label], errors="replace"),
                encoding="utf-8",
            )
        return pref_con.execute(
            f"SELECT * FROM read_csv('{norm}', all_varchar=true)"
        ).to_arrow_table()

    def add_pref_column(tbl, pref_name):
        col = pa.array([pref_name] * tbl.num_rows, type=pa.string())
        return tbl.add_column(0, pa.field("都道府県", pa.string()), col)

    def align_to(tbl, schema):
        arrays = []
        for field in schema:
            if field.name in tbl.schema.names:
                arrays.append(tbl.column(field.name))
            else:
                arrays.append(pa.nulls(tbl.num_rows, type=field.type))
        return pa.Table.from_arrays(arrays, schema=schema)

    pref_table = None
    growth = []
    for _name, _fn in TARGETS:
        _p = PREF_DIR / _fn
        _t = add_pref_column(load_pref(_p, sniff(_p)), _name)
        if pref_table is None:
            pref_table = pref_catalog.create_table("jp.population", schema=_t.schema)
            pref_table.append(_t)
        else:
            with pref_table.update_schema() as _us:
                _us.union_by_name(_t.schema)
            pref_table.append(align_to(_t, pref_table.schema().as_arrow()))
        growth.append(
            {
                "追加した県": _name,
                "この県の列数": _t.num_columns,
                "この県の行数": _t.num_rows,
                "統合後の列数": len(pref_table.schema().fields),
                "snapshot": len(pref_table.history()),
            }
        )

    mo.md(
        f"""
        ### スキーマは足し合わされて育つ

        | 追加した県 | この県の列数 | 行数 | 統合後の列数 | snapshot |
        |---|---|---|---|---|
        {chr(10).join(f"| {g['追加した県']} | {g['この県の列数']} | {g['この県の行数']} | {g['統合後の列数']} | {g['snapshot']} |" for g in growth)}

        4県を入れ終えると **{len(pref_table.schema().fields)}列**になる。
        既存行に無い列は NULL のまま保たれ、読み込みは壊れない。
        DuckDB の `read_csv` は Shift_JIS を読めないので、
        `encoding` 指定を県ごとに変える前処理だけは避けられない。
        """
    )
    return (
        TARGETS,
        add_pref_column,
        align_to,
        duckdb,
        growth,
        load_pref,
        pa,
        pref_con,
        pref_table,
    )


@app.cell
def _(mo, pl, pref_table):
    # 統合テーブルを1本のクエリで引く。県ごとにどの列が埋まっているか。
    merged = pl.from_arrow(pref_table.scan().to_arrow())

    fill = (
        merged.group_by("都道府県")
        .agg(
            [
                pl.len().alias("行数"),
                pl.col("人口総数").is_not_null().sum().alias("人口総数"),
                pl.col("総人口").is_not_null().sum().alias("総人口"),
                pl.col("男(人)").is_not_null().sum().alias("男(人)"),
                pl.col("市区町村").is_not_null().sum().alias("市区町村"),
                pl.col("市町村名").is_not_null().sum().alias("市町村名"),
                pl.col("地方公共団体名").is_not_null().sum().alias("地方公共団体名"),
            ]
        )
        .sort("都道府県")
    )

    mo.md(
        f"""
        ### 1つのテーブル、1本のSQL

        合計 **{len(merged)}行 / {len(merged.columns)}列**。
        県ごとに埋まっている列が違うことがそのまま見える。

        {fill.to_pandas().to_markdown(index=False) if False else ""}
        """
    )
    return fill, merged


@app.cell
def _(fill, mo):
    mo.ui.table(fill, selection=None)
    return


@app.cell
def _(merged, mo, pl):
    # 「人口」を横断で取り出す。県ごとに列が違うので coalesce で寄せる。
    # 栃木は総数列が無いので男+女を足す。
    unified = (
        merged.with_columns(
            [
                pl.coalesce(
                    pl.col("市区町村"),
                    pl.col("市町村名"),
                    pl.col("地方公共団体名"),
                    pl.col("市区町村名"),
                ).alias("市町村"),
                pl.coalesce(
                    pl.col("人口総数").str.replace_all(",", "").cast(pl.Int64, strict=False),
                    pl.col("総人口").str.replace_all(",", "").cast(pl.Int64, strict=False),
                    (
                        pl.col("男(人)").str.replace_all(",", "").cast(pl.Int64, strict=False)
                        + pl.col("女(人)").str.replace_all(",", "").cast(pl.Int64, strict=False)
                    ),
                ).alias("人口"),
            ]
        )
        .select("都道府県", "市町村", "人口")
        .filter(pl.col("人口").is_not_null() & pl.col("市町村").is_not_null())
    )

    top = unified.sort("人口", descending=True).head(12)

    mo.md(
        f"""
        ### 横断クエリの結果

        4県 **{len(unified)}行**を同じ形で取り出せた。
        `coalesce` で列名の違いを寄せ、栃木だけ `男(人) + 女(人)` を計算している。
        この寄せ方をSQLに書けるのは、**元の列を捨てずに全部入れてある**から。

        人口上位:

        {chr(10).join(f"- {r['都道府県']} {r['市町村']}: {r['人口']:,}" for r in top.to_dicts())}
        """
    )
    return top, unified


@app.cell
def _(OUT, alt, col_chart, fill, json, merged, platform_chart, schemas, unified):
    # スライド用の成果物を書き出す
    for _nm, _ch in (("pref_columns", col_chart), ("pref_platforms", platform_chart)):
        _ch.properties(config={"font": "Hiragino Sans"}).save(str(OUT / f"{_nm}.png"), ppi=144)

    pref_summary = {
        "files": len(schemas),
        "encodings": {r["encoding"]: r["len"] for r in schemas.group_by("encoding").len().to_dicts()},
        "columns_min": int(schemas["n_columns"].min()),
        "columns_max": int(schemas["n_columns"].max()),
        "header_not_first_row": [
            {"pref": r["pref"], "header_row": r["header_row"]}
            for r in schemas.to_dicts()
            if r["header_row"] > 1
        ],
        "merged": {"rows": len(merged), "columns": len(merged.columns)},
        "unified_rows": len(unified),
        "per_pref_fill": fill.to_dicts(),
        "headers": {r["pref"]: r["header"] for r in schemas.to_dicts()},
    }
    (OUT / "prefecture_comparison.json").write_text(
        json.dumps(pref_summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps({k: v for k, v in pref_summary.items() if k != "headers"}, ensure_ascii=False, indent=2))
    return pref_summary


@app.cell
def _(mo):
    mo.md(
        """
        ## まとめ

        - 39都道府県のうち、市町村別人口を**CSVで出しているのは半分に満たない**
        - 出している県の間でも、文字コード・列数・ヘッダ位置・単位表記が揃っていない
        - CKANは少数派で、最大勢力は九州発の共同基盤 BODIK
        - 揃っていないまま Iceberg に積み、読むときに寄せる形にできる
        - ただし **文字コードの差だけは取り込み前に解決する必要がある**
        """
    )
    return


@app.cell
def _():
    # altair は後続セルで import するため、依存順を明示するためのダミー
    alt_ready = True
    return (alt_ready,)


if __name__ == "__main__":
    app.run()
