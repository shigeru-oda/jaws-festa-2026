#!/usr/bin/env bash
# data/akita_nenreikakusai/ を秋田県オープンデータカタログサイトから取り直す。
#
# 出典: 「年齢別人口流動調査（県・市町村の年齢各歳、男女別人口）」(秋田県)
#        秋田県オープンデータカタログサイト, CC BY 4.0
#        https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_032
#
# 月報(050008_toukeika_031)と同じ調査だが、こちらは5年ブロックで配布されていて
# 2020〜2025 ブロックだけ 128 列 -> 127 列に減っている。位置108の `年齢不詳` が
# 消え、以降の年齢階級 20 列が1つ左にずれる。Terraform(athena_drift.tf)が
# このディレクトリをそのまま S3 に上げ、「参照先がずれる」検証に使う。
#
# 使い方:
#   ./scripts/fetch_nenreikakusai.sh            # 取得して列構成を検査する
#   ./scripts/fetch_nenreikakusai.sh --check    # 取得せず手元のファイルだけ検査する

set -euo pipefail

DATASET="050008_toukeika_032"
API="https://ckan.pref.akita.lg.jp/api/3/action/package_show?id=${DATASET}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/data/akita_nenreikakusai"

mkdir -p "$DEST"

if [[ "${1:-}" != "--check" ]]; then
  echo "== CKAN からリソース一覧を取得する"
  META="$(mktemp)"
  trap 'rm -f "$META"' EXIT
  curl -sS --fail "$API" -o "$META"

  python3 - "$META" "$DEST" <<'PY'
import json, os, re, sys, urllib.request

meta, dest = sys.argv[1], sys.argv[2]
res = json.load(open(meta))["result"]["resources"]
csvs = [r for r in res if r["format"] == "CSV"]
print(f"   CSV {len(csvs)} 本 / 全リソース {len(res)} 本")

# リソース名の先頭年をブロック名にする(配布ファイル名は年が入らない形があるため)
for r in sorted(csvs, key=lambda x: x["name"]):
    m = re.search(r"(\d{4})\(", r["name"])
    if not m:
        sys.exit(f"リソース名から先頭年が取れない: {r['name']}")
    name = f"pref_nenreikakusai_{m.group(1)}.csv"
    path = os.path.join(dest, name)
    urllib.request.urlretrieve(r["url"], path)
    print(f"   {name}  {os.path.getsize(path):>9,} bytes  <- {r['name']}")
PY
fi

echo "== 列構成を検査する"
python3 - "$DEST" <<'PY'
import csv, glob, io, os, sys, collections

dest = sys.argv[1]
files = sorted(glob.glob(os.path.join(dest, "pref_nenreikakusai_*.csv")))
if not files:
    sys.exit("data/akita_nenreikakusai/ が空。--check を外して取得すること。")

blocks, failures = [], []
for path in files:
    block = os.path.basename(path)[-8:-4]
    raw = open(path, "rb").read()
    rows = list(csv.reader(io.StringIO(raw.decode("utf-8-sig"))))
    header, body = [c.strip() for c in rows[0]], rows[1:]
    years = sorted({r[1].strip()[:4] for r in body if len(r) > 1 and r[1].strip()[:4].isdigit()})
    regions = {}
    for r in body:
        regions.setdefault(r[1].strip()[:4], set()).add(r[3].strip())
    blocks.append((block, header, len(body), years, regions))
    if not raw.startswith(b"\xef\xbb\xbf"):
        failures.append(f"{block}: UTF-8 BOM が無い")

widths = collections.Counter(len(h) for _, h, _, _, _ in blocks)
print(f"   ブロック {len(blocks)} 本 / 列数の分布 {dict(widths)}")
for block, header, nrows, years, regions in blocks:
    span = f"{years[0]}-{years[-1]}" if years else "?"
    sizes = sorted({len(v) for v in regions.values()})
    print(f"   {block} ブロック: 列{len(header):>4} 行{nrows:>5} 収録年 {span} 地域数 {sizes}")

wide = [b for b in blocks if len(b[1]) == 128]
narrow = [b for b in blocks if len(b[1]) == 127]
if len(wide) != 8 or len(narrow) != 1:
    failures.append(f"128列が {len(wide)} 本 / 127列が {len(narrow)} 本(8本と1本のはず)")

# 128列の8ブロックは見出しが完全一致していること
if wide and len({tuple(h) for _, h, _, _, _ in wide}) != 1:
    failures.append("128列ブロックの見出しが一致しない")

# 127列ブロックは位置107で初めて食い違い、以降が1つ左にずれていること
if wide and narrow:
    a, b = wide[0][1], narrow[0][1]
    first = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), None)
    print(f"   最初に食い違う位置: {first}  {a[first]!r} -> {b[first]!r}")
    if first != 107:
        failures.append(f"食い違いの開始位置が {first}(107 のはず)")
    if a[first] != "年齢不詳":
        failures.append(f"消えた列が {a[first]!r}(年齢不詳 のはず)")
    if a[first + 1:] != b[first:]:
        failures.append("位置108以降が1つ左にずれた形になっていない")
    else:
        print(f"   位置108以降の {len(b) - first} 列がちょうど1つ左にずれている")

if failures:
    print("\n!! 検査に失敗した:")
    for f in failures:
        print("   -", f)
    sys.exit(1)
print("   OK")
PY
