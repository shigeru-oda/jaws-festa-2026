#!/usr/bin/env bash
# silver 層(S3 Tables)に Lake Formation の権限を付与・取り消しする。
#
# このアカウントは S3 Tables と Lake Formation の統合が有効なので、テーブルバケットの
# テーブルは Lake Formation の権限が無いと Athena から引けない(Lake Formation 管理者でも同じ)。
# 権限は「カタログ -> 名前空間(データベース) -> テーブル」の階層ごとに付ける必要がある。
#
#   カタログ  <ACCOUNT>:s3tablescatalog/<テーブルバケット>   DESCRIBE
#   名前空間  akita                                          DESCRIBE
#   テーブル  silver_nenreikakusai{,_128,_127}               SELECT INSERT DELETE DESCRIBE ALTER
#
# 対象(テーブルバケット・名前空間・テーブル名)は `terraform output silver_tables` から読む。
# 先に terraform apply してあること。実行するのは Lake Formation 管理者のロール。
#
# 使い方(terraform/ で実行):
#   ./grant_lakeformation.sh --dry-run                 # 実行するコマンドを表示するだけ
#   ./grant_lakeformation.sh                           # 自分のロールに付与する
#   ./grant_lakeformation.sh --principal <IAMロールARN> # 別のロール(ノートブックの実行ロールなど)に付与する
#   ./grant_lakeformation.sh --revoke                  # 付与したものを取り消す
#
# 環境変数: PROFILE(既定は .prof.local の値) / REGION(既定 ap-northeast-1)

set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-$(cat .prof.local 2>/dev/null || true)}"
REGION="${REGION:-ap-northeast-1}"
TABLE_PERMISSIONS='["SELECT","INSERT","DELETE","DESCRIBE","ALTER"]'

ACTION="grant-permissions"
DRY_RUN=0
PRINCIPAL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --revoke) ACTION="revoke-permissions" ;;
    --principal) PRINCIPAL="${2:?--principal には IAM ロールの ARN を渡す}"; shift ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "不明な引数: $1" >&2; exit 1 ;;
  esac
  shift
done

[[ -n "$PROFILE" ]] || { echo "PROFILE が空。PROFILE=<名前> ./grant_lakeformation.sh で渡す" >&2; exit 1; }
AWS=(aws --profile "$PROFILE" --region "$REGION")

# ── 対象を terraform output から読む ────────────────────────────────────────
OUT="$(terraform output -json silver_tables)"
read -r ACCOUNT_ID BUCKET NAMESPACE <<<"$(python3 -c '
import json, sys
o = json.load(sys.stdin)
arn = o["table_bucket_arn"]           # arn:aws:s3tables:<region>:<account>:bucket/<name>
print(arn.split(":")[4], arn.rsplit("/", 1)[1], o["namespace"])
' <<<"$OUT")"
TABLES=()
while IFS= read -r t; do TABLES+=("$t"); done < <(python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["tables"]))' <<<"$OUT")
CATALOG_ID="${ACCOUNT_ID}:s3tablescatalog/${BUCKET}"

# ── 付与先 ───────────────────────────────────────────────────────────────────
# 指定が無ければ自分のロール。SSO のセッション ARN(assumed-role/...)は Lake Formation に
# 渡せないので、iam get-role でパス込みの IAM ロール ARN に引き直す。
if [[ -z "$PRINCIPAL" ]]; then
  CALLER="$("${AWS[@]}" sts get-caller-identity --query Arn --output text)"
  if [[ "$CALLER" == *":assumed-role/"* ]]; then
    ROLE_NAME="$(cut -d/ -f2 <<<"$CALLER")"
    PRINCIPAL="$("${AWS[@]}" iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
  else
    PRINCIPAL="$CALLER"
  fi
fi

echo "== $ACTION"
echo "   principal : $PRINCIPAL"
echo "   catalog   : $CATALOG_ID"
echo "   namespace : $NAMESPACE"
echo "   tables    : ${TABLES[*]}"
echo

run() {
  local resource="$1" permissions="$2"
  local cmd=("${AWS[@]}" lakeformation "$ACTION"
    --principal "{\"DataLakePrincipalIdentifier\":\"$PRINCIPAL\"}"
    --resource "$resource"
    --permissions "$permissions")
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run]'; printf ' %q' "${cmd[@]}"; echo
  else
    "${cmd[@]}" >/dev/null
    echo "   ok  $permissions  $resource"
  fi
}

# 取り消しは付与の逆順(テーブル -> 名前空間 -> カタログ)
resources=()
resources+=("{\"Catalog\":{\"Id\":\"$CATALOG_ID\"}}|[\"DESCRIBE\"]")
resources+=("{\"Database\":{\"CatalogId\":\"$CATALOG_ID\",\"Name\":\"$NAMESPACE\"}}|[\"DESCRIBE\"]")
for t in "${TABLES[@]}"; do
  resources+=("{\"Table\":{\"CatalogId\":\"$CATALOG_ID\",\"DatabaseName\":\"$NAMESPACE\",\"Name\":\"$t\"}}|$TABLE_PERMISSIONS")
done
if [[ "$ACTION" == "revoke-permissions" ]]; then
  reversed=()
  for ((i = ${#resources[@]} - 1; i >= 0; i--)); do reversed+=("${resources[i]}"); done
  resources=("${reversed[@]}")
fi

for item in "${resources[@]}"; do
  run "${item%%|*}" "${item#*|}"
done

if [[ $DRY_RUN -eq 0 && "$ACTION" == "grant-permissions" ]]; then
  echo
  echo "確認(付与されている権限の一覧):"
  echo "  aws lakeformation list-permissions --profile $PROFILE --region $REGION \\"
  echo "    --principal DataLakePrincipalIdentifier=$PRINCIPAL \\"
  echo "    --resource '{\"Table\":{\"CatalogId\":\"$CATALOG_ID\",\"DatabaseName\":\"$NAMESPACE\",\"TableWildcard\":{}}}'"
fi
