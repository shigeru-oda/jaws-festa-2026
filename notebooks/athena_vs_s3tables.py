"""JAWS FESTA 2026 in AKITA 登壇用 検証ノートブック(2)

CFP で約束した比較「S3 に CSV を置いて Athena で読む素朴な構成」vs
「S3 Tables(マネージド Iceberg)」を、AWS を使わずローカルで再現する。

素の構成の要点は **CSV は列を位置で読む** こと。Athena のドキュメントは
CSV/TSV について「先頭や途中への列追加は不可」「列を削除する必要があるなら
CSV/TSV を使うな」と明記している。
https://docs.aws.amazon.com/athena/latest/ug/handling-schema-updates-chapter.html

ここでは Hive/Athena の CSV テーブル(固定スキーマ + 位置読み + 欠けた列は NULL)を
DuckDB の read_csv(columns=..., null_padding=true) で模擬し、Iceberg 側は
pyiceberg のローカル SQLite カタログで本物の Iceberg テーブルを作って比べる。

題材は秋田県「人口移動理由実態調査」。2019 年に理由の分類が 11 項目 -> 8 項目へ
統合・分割・削除された。同じ調査の前後版を1つのテーブルとして読むと何が起きるか。

実行:
    uv run marimo edit notebooks/athena_vs_s3tables.py   # 対話
    uv run python notebooks/athena_vs_s3tables.py        # スクリプトとして通す

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
        # 素の S3 + Athena と S3 Tables は何が違うのか — ローカル再現

        検証したいのは1点。**年次で列が入れ替わるデータを1つのテーブルとして読むと、
        どちらの構成で何が起きるか。**

        | | 素の構成 (S3 + CSV + Athena) | S3 Tables (Iceberg) |
        |---|---|---|
        | 列の同定 | **位置**(LazySimpleSerDe) | **field ID** |
        | 欠けた列 | NULL 埋め | NULL 埋め |
        | 途中への列追加 | ドキュメントが不可と明記 | 可 |
        | 過去の版 | 自分でプレフィックスを切る | snapshot |

        ローカルでは Athena の代わりに DuckDB を使う。CSV を**固定スキーマ + 位置読み +
        null_padding** で読めば、Hive/Athena の CSV テーブルと同じ振る舞いになる。
        """
    )
    return (mo,)


@app.cell
def _():
    from pathlib import Path

    import duckdb

    ROOT = Path(__file__).resolve().parent.parent
    DATA = ROOT / "data" / "akita_idouriyuu"
    OUT = ROOT / "out"
    OUT.mkdir(exist_ok=True)

    V1_CSV = DATA / "01_kaitousya_2013-2018.csv"  # 2013-2018 / 11 理由
    V2_CSV = DATA / "03_kaitousya_2019-2025.csv"  # 2019-2025 /  8 理由

    con = duckdb.connect()

    def header_of(path):
        """1行目をそのまま列名として取り出す(BOM を除去)。"""
        _line = path.read_text(encoding="utf-8").splitlines()[0]
        return [c.strip() for c in _line.lstrip("\ufeff").split(",")]

    H1 = header_of(V1_CSV)
    H2 = header_of(V2_CSV)
    return DATA, H1, H2, OUT, ROOT, V1_CSV, V2_CSV, con, header_of


@app.cell
def _(H1, H2, mo):
    # 共通の識別列と、版ごとに違う「理由」列を切り分ける
    BASE_COLS = [c for c in H1 if c in H2]
    R1 = [c for c in H1 if c not in BASE_COLS]
    R2 = [c for c in H2 if c not in BASE_COLS]

    mo.md(
        f"""
        ## 2つの版の形

        - 共通の識別列 **{len(BASE_COLS)}**: `{'`, `'.join(BASE_COLS)}`
        - 2013-2018 は **{len(H1)}列**、うち理由系 **{len(R1)}**: `{'`, `'.join(R1)}`
        - 2019-2025 は **{len(H2)}列**、うち理由系 **{len(R2)}**: `{'`, `'.join(R2)}`

        識別列は同じ。**入れ替わったのは理由の分類そのもの**で、しかも列名に `（人）` が
        付いて単位が名前に混ざった。
        """
    )
    return BASE_COLS, R1, R2


@app.cell
def _(H1, H2, mo):
    # 素の構成では「テーブル定義」が1つだけ存在する。最初に作った版(2013-2018)の
    # 19 列がカタログに登録され、以降のファイルもその定義で読まれる。
    ATHENA_COLS = list(H1)
    pos_map = {ATHENA_COLS[_i]: (H2[_i] if _i < len(H2) else None) for _i in range(len(ATHENA_COLS))}

    def _verdict(defined, actual):
        if actual is None:
            return "NULL 埋め"
        if actual == defined:
            return "一致"
        if actual.replace("（人）", "") == defined:
            return "一致(単位表記のみ差)"
        return "**中身が別の項目**"

    _rows = [
        (_i + 1, _n, pos_map[_n] or "—", _verdict(_n, pos_map[_n]))
        for _i, _n in enumerate(ATHENA_COLS)
    ]
    broken = [r for r in _rows if "別の項目" in r[3]]
    nulled = [r for r in _rows if r[3] == "NULL 埋め"]
    _body = "\n".join(f"| {a} | `{b}` | `{c}` | {d} |" for a, b, c, d in _rows)

    mo.md(
        f"""
        ## 素の構成が 2019-2025 のファイルをどう読むか

        テーブル定義は 2013-2018 の {len(ATHENA_COLS)} 列。位置で読むので:

        | 位置 | テーブル定義の列名 | ファイル側の実際の中身 | 判定 |
        |---|---|---|---|
        {_body}

        **{len(broken)} 列が別の項目の値を返し、{len(nulled)} 列が NULL になる。**
        エラーは出ない。
        """
    )
    return ATHENA_COLS, broken, nulled, pos_map


@app.cell
def _(ATHENA_COLS, V1_CSV, V2_CSV, con, mo):
    # Hive/Athena の CSV テーブルを模擬:
    #   - 固定スキーマ(columns=)
    #   - ヘッダ行は skip して位置で読む(header=false, skip=1)
    #   - 足りない列は NULL 埋め(null_padding=true) = Hive の振る舞い
    _colspec = ", ".join(f"'{c}': 'VARCHAR'" for c in ATHENA_COLS)

    def athena_read(path):
        return (
            f"SELECT * FROM read_csv('{path}', header=false, skip=1, "
            f"columns={{{_colspec}}}, null_padding=true, auto_detect=false)"
        )

    con.execute(
        "CREATE OR REPLACE VIEW hive_idouriyuu AS "
        f"{athena_read(V1_CSV)} UNION ALL BY NAME {athena_read(V2_CSV)}"
    )
    hive_rows = con.execute("SELECT count(*) FROM hive_idouriyuu").fetchone()[0]

    mo.md(
        f"""
        ## 素の構成: 1つのテーブルとして読めてしまう

        2ファイル・{hive_rows} 行が1つのテーブルになった。**読み込みは成功する。**
        """
    )
    return athena_read, hive_rows


@app.cell
def _(ATHENA_COLS, con):
    # 「県外転入・男女計・総数」の行を、素の構成(位置読み)で取り出す
    KEY = (
        "WHERE 転出入区分 = '県外転入' AND 男女別 = '男女計' AND 年齢階級 = '総数'"
    )

    def reported(year_prefix):
        _sel = ", ".join(f'"{c}"' for c in ATHENA_COLS)
        return con.execute(
            f"SELECT {_sel} FROM hive_idouriyuu {KEY} "
            f"AND 年月日コード LIKE '{year_prefix}%'"
        ).fetchone()

    rep_2019 = dict(zip(ATHENA_COLS, reported("2019")))
    return KEY, rep_2019, reported


@app.cell
def _(H2, KEY, V2_CSV, con):
    # 2019 の「実際の値」をヘッダどおりに読む(正解セット)
    _sel = ", ".join(f'"{c}"' for c in H2)
    truth_2019 = dict(
        zip(
            [c.replace("（人）", "") for c in H2],
            con.execute(
                f"SELECT {_sel} FROM read_csv('{V2_CSV}', all_varchar=true) "
                f"{KEY} AND 年月日コード LIKE '2019%'"
            ).fetchone(),
        )
    )
    return (truth_2019,)


@app.cell
def _(ATHENA_COLS, BASE_COLS, mo, pos_map, rep_2019, truth_2019):
    def is_mislabeled(defined):
        _src = pos_map[defined]
        return _src is not None and _src != defined and _src.replace("（人）", "") != defined

    mislabeled = [c for c in ATHENA_COLS if c not in BASE_COLS and is_mislabeled(c)]
    # 両方の版に「同じ名前」で存在する項目 = 素の構成の誤りを直接照合できる項目
    comparable = [
        c
        for c in ATHENA_COLS
        if c not in BASE_COLS and c in truth_2019 and rep_2019.get(c) != truth_2019[c]
    ]

    def _mark(defined):
        _src = pos_map[defined]
        if _src is None:
            return "NULL(列が無い)"
        if is_mislabeled(defined):
            return f"**実際は「{_src.replace('（人）', '')}」の値**"
        return ""

    _lines = "\n".join(
        f"| `{c}` | {rep_2019[c] or '—'} | {truth_2019.get(c) or '—'} | {_mark(c)} |"
        for c in ATHENA_COLS
        if c not in BASE_COLS
    )

    mo.md(
        f"""
        ## 静かに間違う: 2019年度・県外転入・男女計・総数

        | 素の構成が報告する項目 | 報告値 | その名前の本当の値 | 判定 |
        |---|---|---|---|
        {_lines}

        **{len(mislabeled)} 項目が別の項目の数字を返している。** クエリは成功し、値も自然な
        大きさなので目視では気づけない。
        """
    )
    return comparable, is_mislabeled, mislabeled


@app.cell
def _(R1, con, mo):
    # よくある健全性チェック(総数 == 理由の合計)が通ってしまうことを確認する
    _reason_cols = [c for c in R1 if c != "総数"]
    _sum_expr = " + ".join(
        f'COALESCE(TRY_CAST("{c}" AS BIGINT), 0)' for c in _reason_cols
    )

    sanity = con.execute(
        f"""
        SELECT
            CASE WHEN CAST(substr(年月日コード, 1, 4) AS INT) <= 2018
                 THEN '2013-2018' ELSE '2019-2025' END AS era,
            count(*) AS n_rows,
            sum(CASE WHEN TRY_CAST("総数" AS BIGINT) = {_sum_expr} THEN 1 ELSE 0 END) AS n_ok
        FROM hive_idouriyuu
        GROUP BY 1 ORDER BY 1
        """
    ).fetchall()

    _tbl = "\n".join(
        f"| {e} | {n} | {ok} | {round(100 * ok / n, 1)}% |" for e, n, ok in sanity
    )

    mo.md(
        f"""
        ## 健全性チェックは通る

        「総数 == 理由の合計」で検算しても壊れを検出できない。理由の**数字は全部そこにあり、
        ラベルだけが入れ替わっている**ため合計は一致する。

        | 版 | 行数 | 検算が一致した行 | 割合 |
        |---|---|---|---|
        {_tbl}
        """
    )
    return (sanity,)


@app.cell
def _(ROOT, mo):
    # ここから Iceberg 側。カタログはローカル SQLite。
    # S3 Tables 本番では load_catalog を REST エンドポイントに差し替える。
    import shutil

    import pyarrow as pa
    from pyiceberg.catalog.sql import SqlCatalog

    WH = ROOT / "work" / "warehouse_cmp"
    if WH.exists():
        shutil.rmtree(WH)
    WH.mkdir(parents=True)

    catalog = SqlCatalog(
        "local",
        **{"uri": f"sqlite:///{WH / 'catalog.db'}", "warehouse": f"file://{WH}"},
    )
    catalog.create_namespace_if_not_exists("akita")

    mo.md(
        """
        ## Iceberg 側

        同じ2ファイルを、**ヘッダどおりの列名で** Iceberg テーブルに入れる。
        v1 で作成し、v2 は `union_by_name` で追記する。
        """
    )
    return WH, catalog, pa, shutil


@app.cell
def _(H1, H2, V1_CSV, V2_CSV, catalog, con, mo, pa):
    def arrow_of(path, cols):
        _sel = ", ".join(f'"{c}"' for c in cols)
        return con.execute(
            f"SELECT {_sel} FROM read_csv('{path}', all_varchar=true)"
        ).to_arrow_table()

    def align(tbl, schema):
        _arrays = [
            tbl.column(f.name)
            if f.name in tbl.schema.names
            else pa.nulls(tbl.num_rows, type=f.type)
            for f in schema
        ]
        return pa.Table.from_arrays(_arrays, schema=schema)

    _t1 = arrow_of(V1_CSV, H1)
    _t2 = arrow_of(V2_CSV, H2)

    ice = catalog.create_table("akita.idouriyuu", schema=_t1.schema)
    ice.append(_t1)
    cols_v1 = len(ice.schema().fields)

    with ice.update_schema() as us:
        us.union_by_name(_t2.schema)
    cols_v2 = len(ice.schema().fields)

    ice.append(align(_t2, ice.schema().as_arrow()))

    hist = ice.history()
    ice_rows = ice.scan().to_arrow().num_rows

    mo.md(
        f"""
        v1 追記後 **{cols_v1}列** -> `union_by_name` 後 **{cols_v2}列**
        （v2 固有の {cols_v2 - cols_v1} 列が足された）。
        全体 **{ice_rows}行 / snapshot {len(hist)}個**。

        位置ではなく名前で足されるので、**旧版の行は新列が NULL、新版の行は旧列が NULL**。
        値が別の項目に流れ込むことがない。
        """
    )
    return align, arrow_of, cols_v1, cols_v2, hist, ice, ice_rows, us


@app.cell
def _(H2, ice, mo):
    import pyarrow.compute as pc

    # pyiceberg の row_filter 文字列パーサは非ASCII列名を扱えないので Arrow 側で絞る
    _scan = ice.scan().to_arrow()
    _m = pc.and_(
        pc.and_(
            pc.equal(_scan.column("転出入区分"), "県外転入"),
            pc.equal(_scan.column("男女別"), "男女計"),
        ),
        pc.and_(
            pc.equal(_scan.column("年齢階級"), "総数"),
            pc.starts_with(_scan.column("年月日コード"), "2019"),
        ),
    )
    ice_row = _scan.filter(_m).to_pylist()[0]

    _lines = "\n".join(
        f"| `{c}` | {ice_row.get(c) or '—'} |" for c in H2 if c not in ("年月日コード", "年月日")
    )

    mo.md(
        f"""
        ### Iceberg から読んだ同じ行

        | 項目 | 値 |
        |---|---|
        {_lines}

        ラベルと値が一致している。旧分類の列(`家業後継` など)はこの行では NULL。
        """
    )
    return ice_row, pc


@app.cell
def _(ice, mo):
    # タイムトラベル: snapshot ごとに行数と列の埋まり方を見る
    timetravel = []
    for _i, _h in enumerate(ice.history(), start=1):
        _s = ice.scan(snapshot_id=_h.snapshot_id).to_arrow()
        _filled = sum(
            1 for c in _s.column_names if _s.column(c).null_count < _s.num_rows
        )
        timetravel.append((_i, _h.snapshot_id, _s.num_rows, len(_s.column_names), _filled))

    _tbl = "\n".join(
        f"| v{a} | `{b}` | {c} | {d} | {e} |" for a, b, c, d, e in timetravel
    )

    mo.md(
        f"""
        ### タイムトラベル

        | 版 | snapshot_id | 行数 | 列数 | 値が入っている列 |
        |---|---|---|---|---|
        {_tbl}

        `scan(snapshot_id=...)` で「2019年の再編前だけの状態」に戻れる。
        素の構成でこれをやるなら、自分で日付プレフィックスを切って別テーブルとして
        管理することになる。
        """
    )
    return (timetravel,)


@app.cell
def _(con, ice, mo):
    # 横断クエリ: 11 理由 -> 8 理由の対応を人間が決めて、2013-2025 を1本の SQL で通す
    con.register("ice_tbl", ice.scan().to_arrow())

    MAPPED = {
        "転勤": ['"転勤"', '"転勤（人）"'],
        "転職・就職": ['"転業・転職"', '"就職"', '"転職・就職（人）"', '"就職（学生）（人）"'],
        "学業": ['"進学・転校"', '"卒業"', '"学業（人）"'],
        "結婚・離婚": ['"結婚・離婚"', '"結婚・離婚（人）"'],
        "退職・同居": ['"親との同居"', '"子・孫との同居"', '"退職・同居（人）"'],
        "住宅事情": ['"住宅事情"', '"住宅事情（人）"'],
        "その他": ['"家業後継"', '"その他"', '"その他（人）"'],
    }

    _exprs = [
        "substr(年月日コード, 1, 4) AS 年",
        'COALESCE(TRY_CAST("総数" AS BIGINT), TRY_CAST("総数（人）" AS BIGINT)) AS 総数',
    ]
    for _label, _srcs in MAPPED.items():
        _terms = " + ".join(f"COALESCE(TRY_CAST({s} AS BIGINT), 0)" for s in _srcs)
        _exprs.append(f'({_terms}) AS "{_label}"')

    unified = con.execute(
        f"""
        SELECT {', '.join(_exprs)}
        FROM ice_tbl
        WHERE 転出入区分 = '県外転出' AND 男女別 = '男女計' AND 年齢階級 = '総数'
        ORDER BY 年
        """
    ).arrow().read_all()
    years = unified.column("年").to_pylist()

    mo.md(
        f"""
        ## 横断クエリ: 2013-2025 を1本の SQL で

        11 理由 -> 8 理由の**意味の対応は人間が決める**。Iceberg がやってくれるのは
        「両方の列が壊れずに共存している」ところまで。

        - 対象: 県外転出・男女計・総数
        - 取得できた年: **{years[0]}〜{years[-1]}（{len(years)}時点）**
        - 出力列: 年 + 総数 + 統合後の {len(MAPPED)} 分類

        素の構成でこれをやると、上で見たとおり **`結婚・離婚` に `住宅事情` の値が入った状態で
        グラフが描ける**。壊れたまま完走するのが一番厄介な失敗の形。
        """
    )
    return MAPPED, unified, years


@app.cell
def _(mo, unified):
    # 統合できても「素直に繋がる」とは限らない。回答総数そのものが2019年に跳ねている。
    _tot = dict(zip(unified.column("年").to_pylist(), unified.column("総数").to_pylist()))
    _jump = round(100 * (_tot["2019"] / _tot["2018"] - 1), 1)

    mo.md(
        f"""
        ### 統合の限界(正直に言うべき点)

        | 年 | 2017 | 2018 | **2019** | 2020 | 2021 |
        |---|---|---|---|---|---|
        | 回答総数 | {_tot['2017']} | {_tot['2018']} | **{_tot['2019']}** | {_tot['2020']} | {_tot['2021']} |

        2019 年に回答総数そのものが **{_jump}%** 増えている。分類の再編と同時に調査の規模か
        方法も変わったということで、**列を寄せても時系列として素直には繋がらない**。

        Iceberg が保証するのは「両方の版が壊れずに1つのテーブルで読める」ところまで。
        比較可能かどうかは統計側の判断で、そこは自動化できない。
        """
    )
    return


@app.cell
def _(OUT, comparable, mo, rep_2019, truth_2019, unified):
    import altair as alt
    import polars as pl

    # 両方の版に同じ名前で存在する項目だけを比べる(公平な比較になるのはここだけ)
    _recs = []
    for _c in comparable:
        _rep = rep_2019.get(_c)
        _recs.append(
            {
                "項目": _c,
                "系列": "素の構成が報告する値",
                "人数": int(_rep) if _rep is not None else 0,
                "表示": str(_rep) if _rep is not None else "NULL(列が無い)",
            }
        )
        _recs.append(
            {
                "項目": _c,
                "系列": "本当の値",
                "人数": int(truth_2019[_c]),
                "表示": str(truth_2019[_c]),
            }
        )

    _df = pl.DataFrame(_recs)
    _base = alt.Chart(
        _df, title="同じ列名が返す値 — 素の S3+Athena 構成 vs 実際 (2019年度・県外転入)"
    ).encode(
        y=alt.Y("項目:N", sort=comparable, title=None),
        x=alt.X("人数:Q", scale=alt.Scale(domain=[0, 620])),
        yOffset=alt.YOffset("系列:N", sort=["素の構成が報告する値", "本当の値"]),
    )
    chart_misread = _base.mark_bar().encode(
        color=alt.Color(
            "系列:N",
            sort=["素の構成が報告する値", "本当の値"],
            scale=alt.Scale(range=["#c0392b", "#2e5f8a"]),
        )
    ) + _base.mark_text(align="left", dx=4, fontSize=11).encode(text="表示:N")
    chart_misread = chart_misread.properties(width=620)


    _long = (
        pl.from_arrow(unified)
        .unpivot(index=["年"], variable_name="理由", value_name="人数")
        .filter(pl.col("理由") != "総数")
    )
    chart_reasons = (
        alt.Chart(
            _long, title="秋田県 県外転出の理由別推移 2013-2025 (11理由->8理由に統合)"
        )
        .mark_line(point=True)
        .encode(x=alt.X("年:O"), y=alt.Y("人数:Q"), color=alt.Color("理由:N"))
        .properties(width=620, height=300)
    )

    for _nm, _ch in (("athena_misread", chart_misread), ("idouriyuu_reasons", chart_reasons)):
        _ch.properties(config={"font": "Hiragino Sans"}).save(
            str(OUT / f"{_nm}.png"), ppi=144
        )

    mo.md("図を `out/athena_misread.png` と `out/idouriyuu_reasons.png` に書き出した。")
    return alt, chart_misread, chart_reasons, pl


@app.cell
def _(V1_CSV, V2_CSV, con, ice, mo):
    import time

    def bench(fn, n=7):
        _ts = []
        for _ in range(n):
            _t0 = time.perf_counter()
            fn()
            _ts.append((time.perf_counter() - _t0) * 1000)
        return min(_ts), sum(_ts) / len(_ts)

    csv_bytes = V1_CSV.stat().st_size + V2_CSV.stat().st_size
    csv_min, csv_avg = bench(
        lambda: con.execute("SELECT count(*) FROM hive_idouriyuu").fetchall()
    )

    ice_files = list(ice.scan().plan_files())
    ice_bytes = sum(f.file.file_size_in_bytes for f in ice_files)
    ice_min, ice_avg = bench(lambda: ice.scan().to_arrow())

    mo.md(
        f"""
        ## 規模と速度

        | | 素の構成 (CSV 2本) | Iceberg |
        |---|---|---|
        | ファイル数 | 2 | {len(ice_files)} |
        | 実サイズ | {csv_bytes / 1024:.1f} KB | {ice_bytes / 1024:.1f} KB |
        | 全件スキャン(最小) | {csv_min:.1f} ms | {ice_min:.1f} ms |
        | 全件スキャン(平均) | {csv_avg:.1f} ms | {ice_avg:.1f} ms |

        この規模では速度は論点にならない。**差が出るのは正しさと運用**。
        """
    )
    return bench, csv_avg, csv_bytes, csv_min, ice_avg, ice_bytes, ice_files, ice_min, time


@app.cell
def _(
    H1,
    H2,
    OUT,
    broken,
    cols_v1,
    cols_v2,
    csv_bytes,
    csv_min,
    hist,
    ice_bytes,
    ice_files,
    ice_min,
    ice_rows,
    mislabeled,
    nulled,
    pos_map,
    rep_2019,
    sanity,
    truth_2019,
    unified,
    years,
):
    import json

    summary = {
        "dataset": "秋田県 人口移動理由実態調査 (CC BY 4.0)",
        "versions": {"2013-2018_cols": len(H1), "2019-2025_cols": len(H2)},
        "athena_style_positional_read": {
            "columns_returning_other_item": len(broken),
            "columns_null_padded": len(nulled),
            "sample_row": "2019年度・県外転入・男女計・総数",
            "mislabeled_in_sample_row": {
                c: {
                    "reported": int(rep_2019[c]),
                    "value_actually_belongs_to": pos_map[c],
                    "true_value_of_this_name": int(truth_2019[c])
                    if truth_2019.get(c)
                    else None,
                }
                for c in mislabeled
            },
            "sanity_check_total_equals_sum": {
                e: {"rows": n, "passed": ok} for e, n, ok in sanity
            },
        },
        "iceberg": {
            "columns_after_v1": cols_v1,
            "columns_after_union_by_name": cols_v2,
            "rows": ice_rows,
            "snapshots": len(hist),
            "data_files": len(ice_files),
            "total_kb": round(ice_bytes / 1024, 1),
            "full_scan_ms_min": round(ice_min, 1),
        },
        "plain_csv": {
            "files": 2,
            "total_kb": round(csv_bytes / 1024, 1),
            "full_scan_ms_min": round(csv_min, 1),
        },
        "cross_era_query": {
            "years": years,
            "respondent_total_by_year": dict(
                zip(unified.column("年").to_pylist(), unified.column("総数").to_pylist())
            ),
        },
    }

    (OUT / "athena_vs_s3tables.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return json, summary


if __name__ == "__main__":
    app.run()
