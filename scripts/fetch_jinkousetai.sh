#!/usr/bin/env bash
# data/akita_jinkousetai/ を秋田県オープンデータカタログサイトから取り直す。
#
# 出典: 「年齢別人口流動調査（月報バックナンバーデータ）」(秋田県)
#        秋田県オープンデータカタログサイト, CC BY 4.0
#        https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_031
#
# CKAN の Action API は認証不要。データセット ID からリソース一覧を引き、
# CSV だけを元のファイル名で落とす。Terraform(athena_jinkousetai.tf)が
# このディレクトリをそのまま S3 に上げる。
#
# 使い方:
#   ./scripts/fetch_jinkousetai.sh            # 取得して列構成を検査する
#   ./scripts/fetch_jinkousetai.sh --check    # 取得せず手元のファイルだけ検査する

set -euo pipefail

DATASET="050008_toukeika_031"
API="https://ckan.pref.akita.lg.jp/api/3/action/package_show?id=${DATASET}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/data/akita_jinkousetai"

mkdir -p "$DEST"

if [[ "${1:-}" != "--check" ]]; then
  echo "== CKAN からリソース一覧を取得する"
  META="$(mktemp)"
  trap 'rm -f "$META"' EXIT
  curl -sS --fail "$API" -o "$META"

  python3 - "$META" "$DEST" <<'PY'
import json, os, sys, urllib.request

meta, dest = sys.argv[1], sys.argv[2]
res = json.load(open(meta))["result"]["resources"]
csvs = [r for r in res if r["format"] == "CSV"]
print(f"   CSV {len(csvs)} 本 / 全リソース {len(res)} 本")

for r in sorted(csvs, key=lambda x: x["url"]):
    name = r["url"].rsplit("/", 1)[-1]
    path = os.path.join(dest, name)
    urllib.request.urlretrieve(r["url"], path)
    print(f"   {name}  {os.path.getsize(path):>7,} bytes")
PY
fi

echo "== 列構成を検査する"
python3 - "$DEST" <<'PY'
import csv, glob, io, os, sys, collections

dest = sys.argv[1]
files = sorted(glob.glob(os.path.join(dest, "050008_jinkousetai_*.csv")))
if not files:
    sys.exit("data/akita_jinkousetai/ が空。--check を外して取得すること。")

groups, rows_total, failures = collections.OrderedDict(), 0, []
for path in files:
    year = os.path.basename(path)[-8:-4]
    raw = open(path, "rb").read()
    rows = list(csv.reader(io.StringIO(raw.decode("utf-8-sig"))))
    header, body = tuple(rows[0]), rows[1:]
    groups.setdefault(header, []).append(year)
    rows_total += len(body)
    if len(header) != 36:
        failures.append(f"{year}: 列数が {len(header)}(36 のはず)")
    if not raw.startswith(b"\xef\xbb\xbf"):
        failures.append(f"{year}: UTF-8 BOM が無い")

print(f"   ファイル {len(files)} 本 / データ行 {rows_total:,} 行 / 見出しの流派 {len(groups)} 種")
for i, (header, years) in enumerate(groups.items(), 1):
    print(f"   流派{i} ({len(years)}年): {' '.join(years)}")

if len(groups) == 2:
    a, b = list(groups)
    diff = [(i, x, y) for i, (x, y) in enumerate(zip(a, b), 1) if x != y]
    print(f"   食い違う列 {len(diff)} / {len(a)}")
    for pos, x, y in diff:
        print(f"      pos {pos:>2}  {x}  <->  {y}")

# 旧名称「県外転入」(位置20) が 県内転入(23) + 転入・県外計(24) と一致するか
ok = masked = ng = 0
for path in files:
    rows = list(csv.reader(io.StringIO(open(path, "rb").read().decode("utf-8-sig"))))
    for row in rows[1:]:
        a, b, c = row[19], row[22], row[23]
        if "***" in (a, b, c):
            masked += 1
        elif int(a) == int(b) + int(c):
            ok += 1
        else:
            ng += 1
print(f"   位置20 = 位置23 + 位置24 : 一致 {ok:,} / 不一致 {ng:,} / 欠測 {masked:,}")
if ng:
    failures.append(f"位置20 の恒等式が {ng} 行で崩れた(原稿の主張と食い違う)")

if failures:
    print("\n!! 検査に失敗した:")
    for f in failures:
        print("   -", f)
    sys.exit(1)
print("   OK")
PY
