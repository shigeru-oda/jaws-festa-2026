#!/usr/bin/env bash
#
# 実機 Athena で「列名のリネームに気づけない」ことを確認する。
#
# ローカルで確定させた機序を、本物の S3 + Glue +
# Athena で再現する。テーブル定義は 2020 年版のヘッダから作り、そこへ 2024 年版
# (26 列が改称されたファイル)を同じプレフィックスに置く。
#
# 同じことを Terraform と保存クエリでやるのが terraform/athena_jinkousetai.tf。
# こちらは単独で動く確認用。
#
# 使い方:
#   aws sts get-caller-identity              # 認証が通っているか確認
#   ./scripts/athena_rename_check.sh setup   # バケット作成 + CSV 配置 + テーブル定義
#   ./scripts/athena_rename_check.sh query   # 検証クエリを実行して結果を表示
#   ./scripts/athena_rename_check.sh teardown # 後片付け(削除は明示的に実行)
#
# 認証は環境の既定(SSO セッションや環境変数)をそのまま使う。
# 特定のプロファイルを使いたいときだけ PROFILE=名前 を指定する。
#
# 環境変数で上書きできる:
#   PROFILE (未設定) / REGION (ap-northeast-1) / PREFIX (jaws-festa-2026)
#
# 注意:
#   - setup は S3 バケットと Glue のデータベース/テーブルを作る。課金は極小
#     (数MBのストレージ + Athena の最小課金 10MB/クエリ x 数本)
#   - teardown は S3 オブジェクトとバケット、Glue テーブル/データベースを削除する
set -euo pipefail

PROFILE="${PROFILE:-}" # 空なら --profile を渡さない(環境の既定認証を使う)
REGION="${REGION:-ap-northeast-1}"
PREFIX="${PREFIX:-jaws-festa-2026}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$ROOT/data/akita"
F_OLD="pref_jinkousetai_2020.csv" # 改称前(この 36 列でテーブル定義を作る)
F_NEW="pref_jinkousetai_2024.csv" # 改称後(26 列が改称。同じ場所に置く)

AWS=(aws --region "$REGION")
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")

die() {
  echo "ERROR: $*" >&2
  exit 1
}

account_id() {
  "${AWS[@]}" sts get-caller-identity --query Account --output text
}

# 2020 年版のヘッダをローマ字化した 36 列。
# Athena は列名にアンダースコア以外の特殊文字を許さないので日本語ヘッダは使えない
# (https://docs.aws.amazon.com/athena/latest/ug/create-table.html)。
# つまり「日本語の列名 -> ローマ字」の対応は人間が持つしかない。ここが今回の要点。
#
# すべて string にしてある。欠損が `***` で入るため数値型にすると読めない行が出る。
# 集計側で TRY_CAST する。
read -r -d '' COLUMNS_DDL <<'DDL' || true
  nengetsubi_code            string,
  nengetsubi                 string,
  kubun_code                 string,
  kubun                      string,
  jinko_danjokei             string,
  jinko_otoko                string,
  jinko_onna                 string,
  jinko_zogen_danjokei       string,
  jinko_zogen_otoko          string,
  jinko_zogen_onna           string,
  shussei_danjokei           string,
  shussei_otoko              string,
  shussei_onna               string,
  shibo_danjokei             string,
  shibo_otoko                string,
  shibo_onna                 string,
  shizen_zogen_danjokei      string,
  shizen_zogen_otoko         string,
  shizen_zogen_onna          string,
  kengai_tennyu_danjokei     string,
  kengai_tennyu_otoko        string,
  kengai_tennyu_onna         string,
  kennai_tennyu_danjokei     string,
  tennyu_kengai_kei          string,
  kengai_tenshutsu_danjokei  string,
  kengai_tenshutsu_otoko     string,
  kengai_tenshutsu_onna      string,
  kennai_tenshutsu_danjokei  string,
  tenshutsu_kengai_kei       string,
  shakai_zogen_danjokei      string,
  shakai_zogen_otoko         string,
  shakai_zogen_onna          string,
  setaisu                    string,
  zoka_setaisu               string,
  gensho_setaisu             string,
  setai_zogensu              string
DDL

# ── Athena クエリの実行 ─────────────────────────────────────────────────────
# start-query-execution -> 完了待ち -> 結果表示 を1つにまとめる
run_query() {
  local label="$1" sql="$2" out="s3://$BUCKET/athena-results/"
  echo
  echo "── $label ──────────────────────────────────────────"
  echo "$sql" | sed 's/^/  | /'

  local qid
  qid="$("${AWS[@]}" athena start-query-execution \
    --query-string "$sql" \
    --result-configuration "OutputLocation=$out" \
    --query QueryExecutionId --output text)"

  local state reason
  for _ in $(seq 1 60); do
    state="$("${AWS[@]}" athena get-query-execution --query-execution-id "$qid" \
      --query 'QueryExecution.Status.State' --output text)"
    case "$state" in
    SUCCEEDED) break ;;
    FAILED | CANCELLED)
      reason="$("${AWS[@]}" athena get-query-execution --query-execution-id "$qid" \
        --query 'QueryExecution.Status.StateChangeReason' --output text)"
      die "クエリが $state: $reason"
      ;;
    esac
    sleep 2
  done
  [[ "$state" == "SUCCEEDED" ]] || die "タイムアウト (QueryExecutionId=$qid)"

  local scanned
  scanned="$("${AWS[@]}" athena get-query-execution --query-execution-id "$qid" \
    --query 'QueryExecution.Statistics.DataScannedInBytes' --output text)"

  "${AWS[@]}" athena get-query-results --query-execution-id "$qid" --output json |
    python3 -c '
import json, sys
rows = json.load(sys.stdin)["ResultSet"]["Rows"]
for r in rows:
    print("  " + " | ".join(c.get("VarCharValue", "") or "" for c in r["Data"]))
'
  echo "  (scanned: ${scanned} bytes / QueryExecutionId: $qid)"
}

cmd_setup() {
  local acct
  acct="$(account_id)" || die "認証に失敗。aws sts get-caller-identity が通る状態にしてから再実行"
  BUCKET="$PREFIX-rename-$acct"
  DB="$(echo "${PREFIX}_akita" | tr '-' '_')"

  [[ -f "$DATA_DIR/$F_OLD" ]] || die "$DATA_DIR/$F_OLD が無い"
  [[ -f "$DATA_DIR/$F_NEW" ]] || die "$DATA_DIR/$F_NEW が無い"

  echo "account=$acct / region=$REGION / bucket=$BUCKET / db=$DB"

  if "${AWS[@]}" s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "バケットは既にある: $BUCKET"
  else
    echo "バケットを作る: $BUCKET"
    "${AWS[@]}" s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=$REGION"
    "${AWS[@]}" s3api put-public-access-block --bucket "$BUCKET" \
      --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    "${AWS[@]}" s3api put-bucket-encryption --bucket "$BUCKET" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  fi

  # 2ファイルを同じプレフィックスに置く。これが「1つのテーブルとして読める」状態を作る。
  echo "CSV を配置する: s3://$BUCKET/jinkousetai/"
  "${AWS[@]}" s3 cp "$DATA_DIR/$F_OLD" "s3://$BUCKET/jinkousetai/$F_OLD"
  "${AWS[@]}" s3 cp "$DATA_DIR/$F_NEW" "s3://$BUCKET/jinkousetai/$F_NEW"

  run_query "データベースを作る" "CREATE DATABASE IF NOT EXISTS $DB"

  # テーブル定義は 2020 年版のヘッダから作る。2024 年版も同じ定義で読まれる。
  run_query "テーブルを作る(定義は 2020 年版の 36 列)" "
CREATE EXTERNAL TABLE IF NOT EXISTS $DB.jinkousetai_csv (
$COLUMNS_DDL
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION 's3://$BUCKET/jinkousetai/'
TBLPROPERTIES ('skip.header.line.count'='1', 'classification'='csv')"

  echo
  echo "setup 完了。次: ./scripts/athena_rename_check.sh query"
}

cmd_query() {
  local acct
  acct="$(account_id)" || die "認証に失敗。aws sts get-caller-identity を確認"
  BUCKET="$PREFIX-rename-$acct"
  DB="$(echo "${PREFIX}_akita" | tr '-' '_')"

  # 1) 2024 年版を足してもテーブル定義は 2020 年版の列名のまま = リネームが見えない
  run_query "テーブル定義の列名(2024 年版を置いた後も変わらない)" "
SELECT column_name, ordinal_position
FROM information_schema.columns
WHERE table_schema = '$DB' AND table_name = 'jinkousetai_csv'
  AND ordinal_position IN (20, 23, 24)
ORDER BY ordinal_position"

  # 2) 両年が1テーブルとして読める(エラーが出ない)
  run_query "行数(2ファイル分が1テーブルになる)" "
SELECT substr(nengetsubi_code, 1, 4) AS era, count(*) AS row_count
FROM $DB.jinkousetai_csv
GROUP BY 1 ORDER BY 1"

  # 3) 本題。「県外転入」という名前の列が実際には何を返すか
  run_query "『県外転入』として集計した値 vs 実際の県外" "
SELECT substr(nengetsubi_code, 1, 4) AS era,
       kubun,
       TRY_CAST(kengai_tennyu_danjokei AS bigint) AS believed_kengai,
       TRY_CAST(kennai_tennyu_danjokei AS bigint) AS kennai,
       TRY_CAST(tennyu_kengai_kei      AS bigint) AS actual_kengai,
       round(100.0 * TRY_CAST(kengai_tennyu_danjokei AS bigint)
             / TRY_CAST(tennyu_kengai_kei AS bigint) - 100, 1) AS overstated_pct
FROM $DB.jinkousetai_csv
WHERE kubun IN ('市部計', '郡部計', '秋田市')
  AND nengetsubi_code LIKE '%000101'
ORDER BY era, kubun"

  # 4) 「県外転入」列が実は合計であることの検算(両年で成立する = 意味は不変)
  run_query "検算: 定義上の県外転入 == 県内 + 県外 が成立する行数" "
SELECT substr(nengetsubi_code, 1, 4) AS era,
       count(*) AS total_rows,
       sum(CASE WHEN TRY_CAST(kengai_tennyu_danjokei AS bigint)
                   = TRY_CAST(kennai_tennyu_danjokei AS bigint)
                   + TRY_CAST(tennyu_kengai_kei AS bigint)
                THEN 1 ELSE 0 END) AS passed
FROM $DB.jinkousetai_csv
GROUP BY 1 ORDER BY 1"

  echo
  echo "期待する結果(ローカル再現と一致するか):"
  echo "  - 列名は kengai_tennyu_danjokei のまま(2024 年版の 転入・合計 は現れない)"
  echo "  - 行数は 2020 / 2024 が各 408 行、合計 816 行"
  echo "  - 市部計 2020 は 1125 / 486 / 639 で overstated_pct = 76.1"
  echo "  - 郡部計 2020 は 104 / 59 / 45 で overstated_pct = 131.1"
  echo "  - 検算は両年 396 行で成立(残り 12 行は *** 欠損)"
}

cmd_teardown() {
  local acct
  acct="$(account_id)" || die "認証に失敗。aws sts get-caller-identity を確認"
  BUCKET="$PREFIX-rename-$acct"
  DB="$(echo "${PREFIX}_akita" | tr '-' '_')"

  echo "以下を削除する:"
  echo "  - Glue テーブル $DB.jinkousetai_csv"
  echo "  - Glue データベース $DB"
  echo "  - S3 バケット $BUCKET (中身ごと)"
  read -r -p "続行する? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || {
    echo "中止"
    exit 0
  }

  "${AWS[@]}" glue delete-table --database-name "$DB" --name jinkousetai_csv 2>/dev/null || true
  "${AWS[@]}" glue delete-database --name "$DB" 2>/dev/null || true
  "${AWS[@]}" s3 rm "s3://$BUCKET" --recursive || true
  "${AWS[@]}" s3api delete-bucket --bucket "$BUCKET" || true
  echo "削除しました"
}

case "${1:-}" in
setup) cmd_setup ;;
query) cmd_query ;;
teardown) cmd_teardown ;;
*)
  sed -n '3,25p' "${BASH_SOURCE[0]}" | sed -n 's/^#\{1,\} \{0,1\}//p'
  exit 1
  ;;
esac
