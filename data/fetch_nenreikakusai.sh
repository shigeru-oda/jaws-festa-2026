#!/usr/bin/env bash
# data/akita_nenreikakusai/ に秋田県オープンデータカタログサイトから CSV を落とす。
#
# 出典: 「年齢別人口流動調査（県・市町村の年齢各歳、男女別人口）」(秋田県)
#        秋田県オープンデータカタログサイト, CC BY 4.0
#        https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_032
#
# 使い方:
#   ./data/fetch_nenreikakusai.sh
#
# 保存名は pref_nenreikakusai_<先頭年>.csv。既存ファイルは上書きする。

set -euo pipefail

DATASET="050008_toukeika_032"
API="https://ckan.pref.akita.lg.jp/api/3/action/package_show?id=${DATASET}"
DEST="$(cd "$(dirname "$0")" && pwd)/akita_nenreikakusai"

mkdir -p "$DEST"

# リソース一覧から CSV だけを「先頭年<TAB>URL」の形で取り出す
curl -sS --fail "$API" | python3 -c '
import json, re, sys
for r in json.load(sys.stdin)["result"]["resources"]:
    if r["format"] != "CSV":
        continue
    m = re.search(r"(\d{4})\(", r["name"])
    if not m:
        sys.exit("リソース名から先頭年が取れない: " + r["name"])
    print(m.group(1) + "\t" + r["url"])
' | while IFS=$'\t' read -r year url; do
  out="$DEST/pref_nenreikakusai_${year}.csv"
  curl -sS --fail -o "$out" "$url"
  echo "$out"
done
