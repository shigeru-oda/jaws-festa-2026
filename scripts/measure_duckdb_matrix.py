#!/usr/bin/env python3
"""スライド「【参考】DuckDBの場合」の表の一次情報を作る。

スキーマが変わった2ファイルを1つのテーブルとして読み、形式と読み方ごとに
何が起きるかを分類して `out/duckdb_schema_matrix.json` に落とす。

このスクリプトだけは duckdb に依存する(他の scripts/*.py は標準ライブラリのみ)。
pyproject.toml には足さず、使い捨ての環境で動かす:

    uv run --with duckdb --no-project python scripts/measure_duckdb_matrix.py

分類(スライドの凡例と対応):

| 記号   | 意味                                       |
| ------ | ------------------------------------------ |
| ○      | 全行の値が正しい                           |
| NULL   | 値が取れず NULL になる                     |
| ズレ   | 別の列の値が入る                           |
| エラー | 読み込みに失敗する                         |

`列の名前変更` の ○ は「値は正しいがラベルが古い」という意味。位置で読むと
旧名のまま新しい版の値が返るので、値としては正しく、名前だけが過去のものになる。
本編で言う「気づけない」はこの状態を指す。
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

try:
    import duckdb
except ModuleNotFoundError:  # pragma: no cover
    sys.exit(
        "duckdb が無い。次で実行する:\n"
        "  uv run --with duckdb --no-project python scripts/measure_duckdb_matrix.py"
    )

OUT = Path(__file__).resolve().parent.parent / "out" / "duckdb_schema_matrix.json"

# テーブル定義(最初に作った版)。id 以外は数値列。
BASE = ["id", "col_a", "col_b", "col_c"]
BASE_TYPES = {"id": "VARCHAR", "col_a": "INTEGER", "col_b": "INTEGER", "col_c": "INTEGER"}

# 1つ目のファイル(定義どおり)の行
V1_ROW = {"id": "v1", "col_a": 11, "col_b": 12, "col_c": 13}

# 2つ目のファイルの行。意味は同じで、スキーマだけが変わる。
V2_TRUTH = {"col_a": 21, "col_b": 22, "col_c": 23}

# scenario -> (2つ目のファイルの列と値, col_c に期待する値)
#   col_c の期待値が None の場合は「NULL が正しい」を意味する(retype)
SCENARIOS: dict[str, tuple[list[tuple[str, object]], object]] = {
    "列の名前変更": (
        [("id", "v2"), ("col_a", 21), ("col_b", 22), ("col_c_new", 23)],
        23,
    ),
    "先頭または中間に列を追加": (
        [("id", "v2"), ("col_a", 21), ("col_new", 29), ("col_b", 22), ("col_c", 23)],
        23,
    ),
    "末尾に列を追加": (
        [("id", "v2"), ("col_a", 21), ("col_b", 22), ("col_c", 23), ("col_new", 29)],
        23,
    ),
    "列の削除": (  # 中間の col_b を落とす(本編の 年齢不詳 と同じ位置関係)
        [("id", "v2"), ("col_a", 21), ("col_c", 23)],
        23,
    ),
    "列の順序変更": (
        [("id", "v2"), ("col_a", 21), ("col_c", 23), ("col_b", 22)],
        23,
    ),
    "列のデータ型の変更": (  # 数値列に数値でない値が入る
        [("id", "v2"), ("col_a", 21), ("col_b", 22), ("col_c", "-")],
        None,
    ),
}

COLUMNS_SPEC = "{" + ", ".join(f"'{c}': '{BASE_TYPES[c]}'" for c in BASE) + "}"

# 位置指定(Athena 模擬)用。Hive の LazySimpleSerDe は宣言より多い項目を黙って捨て、
# 少ない行は NULL で埋める。DuckDB の columns= は項目が多い行をエラーにするので、
# いちばん広いファイルに合わせた列数で読み、先頭4列だけを取り出して同じ動きにする。
PAD_COLUMNS = 8
PAD_SPEC = "{" + ", ".join(
    f"'{c}': '{BASE_TYPES[c]}'" for c in BASE
) + ", " + ", ".join(f"'_extra{i}': 'VARCHAR'" for i in range(PAD_COLUMNS - len(BASE))) + "}"


def reader(kind: str, paths: list[str]) -> str:
    """ファイル2本を1つのテーブルとして読む式を返す。"""
    lst = "[" + ", ".join(f"'{p}'" for p in paths) + "]"
    return {
        "CSV 既定": f"read_csv({lst})",
        "CSV union_by_name": f"read_csv({lst}, union_by_name=true)",
        # Athena(LazySimpleSerDe)の模擬。見出しを捨てて位置で読む。
        # 多い項目は捨て、少ない行は NULL で埋める。
        "CSV 位置指定": (
            f"read_csv({lst}, header=false, skip=1, columns={PAD_SPEC}, "
            "null_padding=true, auto_detect=false)"
        ),
        "Parquet 既定": f"read_parquet({lst})",
        "Parquet union_by_name": f"read_parquet({lst}, union_by_name=true)",
        "JSON union_by_name": f"read_json({lst}, union_by_name=true)",
        "AVRO": f"read_avro({lst})",
    }[kind]


READERS = [
    "CSV 既定",
    "CSV union_by_name",
    "CSV 位置指定",
    "Parquet 既定",
    "Parquet union_by_name",
    "JSON union_by_name",
    "AVRO",
]

FORMAT_OF = {
    "CSV 既定": "csv",
    "CSV union_by_name": "csv",
    "CSV 位置指定": "csv",
    "Parquet 既定": "parquet",
    "Parquet union_by_name": "parquet",
    "JSON union_by_name": "json",
    "AVRO": "avro",
}


def write_file(con, fmt: str, path: Path, cols: list[tuple[str, object]]) -> None:
    """1行だけのファイルを指定形式で書く。"""
    sel = ", ".join(
        (f"{v} AS {k}" if isinstance(v, int) else f"'{v}' AS {k}") for k, v in cols
    )
    con.execute(f"COPY (SELECT {sel}) TO '{path}' (FORMAT {fmt})")


def classify(rows: list[tuple], expect_c: object) -> str:
    """v2 の行が返した値を見て分類する。"""
    v2 = [r for r in rows if r[0] == "v2"]
    if not v2:
        return "行が消える"
    truth = {"col_a": V2_TRUTH["col_a"], "col_b": V2_TRUTH["col_b"], "col_c": expect_c}
    # 他の列の真値の集合(どの列の値が紛れ込んだか判定するため)
    others = set(V2_TRUTH.values()) | {29}
    got_null = False
    for row in v2:
        for name, value in zip(BASE[1:], row[1:]):
            want = truth[name]
            if value == want:
                continue
            if value is None:
                got_null = True
                continue
            if isinstance(value, str) and value.strip('"') == "-":
                # 型が広がって数値でない値がそのまま入る
                return "文字列として読む"
            if value in others:
                return "ズレ"
            return f"値が違う({name}={value})"
    return "NULL" if got_null else "○"


def main() -> int:
    con = duckdb.connect()
    con.execute("INSTALL avro; LOAD avro;")
    version = con.sql("SELECT version()").fetchone()[0]

    results: dict[str, dict[str, str]] = {}
    tmp = Path(tempfile.mkdtemp(prefix="duckdb-matrix-"))
    try:
        for scenario, (v2_cols, expect_c) in SCENARIOS.items():
            results[scenario] = {}
            for rd in READERS:
                fmt = FORMAT_OF[rd]
                ext = {"csv": "csv", "parquet": "parquet", "json": "json", "avro": "avro"}[fmt]
                p1 = tmp / f"v1.{ext}"
                p2 = tmp / f"v2.{ext}"
                try:
                    write_file(con, fmt, p1, list(V1_ROW.items()))
                    write_file(con, fmt, p2, v2_cols)
                except Exception as exc:  # 書き出せない形式はそこで記録して終わり
                    results[scenario][rd] = f"書き出し不可({type(exc).__name__})"
                    continue
                cols = ", ".join(BASE)
                sql = f"SELECT {cols} FROM {reader(rd, [str(p1), str(p2)])} ORDER BY id"
                try:
                    rows = con.sql(sql).fetchall()
                except Exception:
                    results[scenario][rd] = "エラー"
                    continue
                results[scenario][rd] = classify(rows, expect_c)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    payload = {
        "measured_on": date.today().isoformat(),
        "duckdb_version": version,
        "how_to_rerun": (
            "uv run --with duckdb --no-project python scripts/measure_duckdb_matrix.py"
        ),
        "legend": {
            "○": "全行の値が正しい",
            "NULL": "値が取れず NULL になる",
            "ズレ": "別の列の値が入る",
            "文字列として読む": "型が広がり、数値でない値がそのまま入る",
            "エラー": "読み込みに失敗する",
        },
        "notes": [
            "テーブル定義は id/col_a/col_b/col_c の4列。id 以外は数値列。",
            "2つ目のファイルは意味は同じでスキーマだけが変わる。col_a=21 / col_b=22 / col_c=23 が正しい値。",
            "列の削除は中間の col_b を落としている(本編の 年齢不詳 と同じ位置関係)。",
            "「列の名前変更」の ○ は値は正しいがラベルが古い状態。位置で読むと旧名のまま新版の値が返る。",
            "「列の削除」の NULL は意味としては正しい(その版に列が無い)。ズレと違い値は混ざらない。",
            "位置指定は Hive の LazySimpleSerDe の模擬。宣言より多い項目は捨て、少ない行は NULL で埋める。"
            "DuckDB の columns= は項目が多い行をエラーにするため、広い列数で読んで先頭4列を取り出している。",
            "位置指定の「列のデータ型の変更」は DuckDB ではエラーになるが、"
            "Athena は数値列に読めない値が来ると NULL を返す(bronze を全列 string にしている理由)。",
            "ORC は duckdb 1.5.6 に拡張が無く(extensions.duckdb.org が 404)、読み書きとも試せないので列を外した。",
        ],
        "matrix": results,
    }
    OUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    width = max(len(s) for s in SCENARIOS)
    print(f"duckdb {version}")
    print(" " * width + "  " + "  ".join(f"{r:<22}" for r in READERS))
    for scenario in SCENARIOS:
        cells = "  ".join(f"{results[scenario][r]:<22}" for r in READERS)
        print(f"{scenario:<{width}}  {cells}")
    print(f"\n-> {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
