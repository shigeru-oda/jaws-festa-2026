#!/usr/bin/env bash
#
# 実機 Athena で「列が消えると同じ位置の意味が変わる」ことを確認する。
#
# 壊れ方その2。列名だけが変わる athena_rename_check.sh と違い、こちらは
# 列そのものが減るので位置がずれ、**値が別の項目に流れ込む**。
#
# 題材は秋田県の人口移動理由実態調査。2019 年に理由の分類が 11 項目から 8 項目へ
# 再編された(統合・分割・削除が同時)。旧版 19 列の定義で新版 16 列のファイルを読む。
#
# 使い方:
#   aws sts get-caller-identity             # 認証が通っているか確認
#   ./scripts/athena_shift_check.sh setup   # バケット作成 + CSV 配置 + テーブル定義
#   ./scripts/athena_shift_check.sh query   # 検証クエリを実行して結果を表示
#   ./scripts/athena_shift_check.sh teardown # 後片付け(削除は明示的に実行)
#
# 認証は環境の既定(SSO セッションや環境変数)をそのまま使う。
# 特定のプロファイルを使いたいときだけ PROFILE=名前 を指定する。
#
# 環境変数で上書きできる:
#   PROFILE (未設定) / REGION (ap-northeast-1) / PREFIX (jaws-festa-2026)
#
# バケットと Glue データベースは athena_rename_check.sh とは別名にしてある。
# 片方の teardown がもう片方を壊さないようにするため。
set -euo pipefail

PROFILE="${PROFILE:-}"
REGION="${REGION:-ap-northeast-1}"
PREFIX="${PREFIX:-jaws-festa-2026}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$ROOT/data/akita_idouriyuu"
F_OLD="01_kaitousya_2013-2018.csv" # 19 列。この定義でテーブルを作る
F_NEW="03_kaitousya_2019-2025.csv" # 16 列。同じ場所に置く

AWS=(aws --region "$REGION")
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")

TABLE="idouriyuu_csv"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

account_id() {
  "${AWS[@]}" sts get-caller-identity --query Account --output text
}

# 旧版(2013-2018)のヘッダをローマ字化した 19 列。
# Athena は列名にアンダースコア以外の特殊文字を許さないので日本語は使えない。
# 全列 string にして集計側で TRY_CAST する。
read -r -d '' COLUMNS_DDL <<'DDL' || true
  nengetsubi_code   string,
  nengetsubi        string,
  idou_kubun_code   string,
  idou_kubun        string,
  danjo_code        string,
  danjo             string,
  nenrei_kaikyu     string,
  sosu              string,
  tenkin            string,
  tengyo_tenshoku   string,
  shushoku          string,
  kagyo_kokei       string,
  shingaku_tenko    string,
  sotsugyo          string,
  kekkon_rikon      string,
  oya_to_dokyo      string,
  ko_mago_to_dokyo  string,
  jutaku_jijo       string,
  sonota            string
DDL

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
    print("  " + " | ".join(c.get("VarCharValue", "") or "(null)" for c in r["Data"]))
'
  echo "  (scanned: ${scanned} bytes / QueryExecutionId: $qid)"
}

resolve_names() {
  local acct
  acct="$(account_id)" || die "認証に失敗。aws sts get-caller-identity を確認"
  BUCKET="$PREFIX-shift-$acct"
  DB="$(echo "${PREFIX}_idouriyuu" | tr '-' '_')"
}

cmd_setup() {
  resolve_names
  [[ -f "$DATA_DIR/$F_OLD" ]] || die "$DATA_DIR/$F_OLD が無い"
  [[ -f "$DATA_DIR/$F_NEW" ]] || die "$DATA_DIR/$F_NEW が無い"

  echo "region=$REGION / bucket=$BUCKET / db=$DB / table=$TABLE"

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

  echo "CSV を配置する: s3://$BUCKET/idouriyuu/"
  "${AWS[@]}" s3 cp "$DATA_DIR/$F_OLD" "s3://$BUCKET/idouriyuu/$F_OLD"
  "${AWS[@]}" s3 cp "$DATA_DIR/$F_NEW" "s3://$BUCKET/idouriyuu/$F_NEW"

  run_query "データベースを作る" "CREATE DATABASE IF NOT EXISTS $DB"

  run_query "テーブルを作る(定義は旧版 2013-2018 の 19 列)" "
CREATE EXTERNAL TABLE IF NOT EXISTS $DB.$TABLE (
$COLUMNS_DDL
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION 's3://$BUCKET/idouriyuu/'
TBLPROPERTIES ('skip.header.line.count'='1', 'classification'='csv')"

  echo
  echo "setup 完了。次: ./scripts/athena_shift_check.sh query"
}

cmd_query() {
  resolve_names

  # 1) 16 列のファイルを足しても定義は 19 列のまま。学業/退職・同居 は現れない
  run_query "テーブル定義の列名(位置10-19)" "
SELECT ordinal_position, column_name
FROM information_schema.columns
WHERE table_schema = '$DB' AND table_name = '$TABLE'
  AND ordinal_position BETWEEN 10 AND 19
ORDER BY ordinal_position"

  # 2) 列数が違う2ファイルが1テーブルとして読める(エラーが出ない)
  run_query "行数(19列の定義で16列のファイルも読める)" "
SELECT CASE WHEN CAST(substr(nengetsubi_code, 1, 4) AS integer) <= 2018
            THEN '2013-2018(19列)' ELSE '2019-2025(16列)' END AS era,
       count(*) AS row_count
FROM $DB.$TABLE
GROUP BY 1 ORDER BY 1"

  # 3) 本題。同じ位置の意味が変わっている
  run_query "旧版の列名で新版を読むと何が返るか(2019年度・県外転入・男女計・総数)" "
SELECT nengetsubi_code,
       sosu,
       tengyo_tenshoku,   -- 実体は 転職・就職
       shushoku,          -- 実体は 就職(学生)
       kagyo_kokei,       -- 実体は 学業。2019年に廃止された項目なのに値が入る
       shingaku_tenko,    -- 実体は 結婚・離婚
       sotsugyo,          -- 実体は 退職・同居
       kekkon_rikon,      -- 実体は 住宅事情。正しい結婚・離婚は 390
       oya_to_dokyo,      -- 実体は その他
       ko_mago_to_dokyo,  -- 列が無い -> NULL
       jutaku_jijo,       -- 列が無い -> NULL
       sonota             -- 列が無い -> NULL
FROM $DB.$TABLE
WHERE idou_kubun = '県外転入' AND danjo = '男女計' AND nenrei_kaikyu = '総数'
  AND nengetsubi_code LIKE '2019%'"

  # 4) 比較用。旧版の同じ行は正しく読める
  run_query "旧版(2013年度)の同じ行。こちらは定義と中身が一致している" "
SELECT nengetsubi_code, sosu, kagyo_kokei, shingaku_tenko, sotsugyo,
       kekkon_rikon, oya_to_dokyo, ko_mago_to_dokyo, jutaku_jijo, sonota
FROM $DB.$TABLE
WHERE idou_kubun = '県外転入' AND danjo = '男女計' AND nenrei_kaikyu = '総数'
  AND nengetsubi_code LIKE '2013%'"

  # 5) 検算をすり抜ける。総数 == 理由の合計 が全行で成立してしまう
  run_query "検算: 総数 == 理由の合計 が成立する行数" "
SELECT CASE WHEN CAST(substr(nengetsubi_code, 1, 4) AS integer) <= 2018
            THEN '2013-2018(19列)' ELSE '2019-2025(16列)' END AS era,
       count(*) AS total_rows,
       sum(CASE WHEN TRY_CAST(sosu AS bigint) =
                     COALESCE(TRY_CAST(tenkin AS bigint), 0)
                   + COALESCE(TRY_CAST(tengyo_tenshoku AS bigint), 0)
                   + COALESCE(TRY_CAST(shushoku AS bigint), 0)
                   + COALESCE(TRY_CAST(kagyo_kokei AS bigint), 0)
                   + COALESCE(TRY_CAST(shingaku_tenko AS bigint), 0)
                   + COALESCE(TRY_CAST(sotsugyo AS bigint), 0)
                   + COALESCE(TRY_CAST(kekkon_rikon AS bigint), 0)
                   + COALESCE(TRY_CAST(oya_to_dokyo AS bigint), 0)
                   + COALESCE(TRY_CAST(ko_mago_to_dokyo AS bigint), 0)
                   + COALESCE(TRY_CAST(jutaku_jijo AS bigint), 0)
                   + COALESCE(TRY_CAST(sonota AS bigint), 0)
                THEN 1 ELSE 0 END) AS passed
FROM $DB.$TABLE
GROUP BY 1 ORDER BY 1"

  cat <<'EXPECT'

期待する結果(ローカル再現と一致するか):
  - 列名は 19 列のまま。kagyo_kokei / shingaku_tenko / sotsugyo が残り、
    新版の 学業 / 退職・同居 に相当する列は現れない
  - 行数は 2013-2018 が 702、2019-2025 が 819(合計 1521)
  - 2019年度の行は
      sosu=5310 / tengyo_tenshoku=1017 / shushoku=384 / kagyo_kokei=295 /
      shingaku_tenko=390 / sotsugyo=926 / kekkon_rikon=117 / oya_to_dokyo=520 /
      ko_mago_to_dokyo, jutaku_jijo, sonota = (null)
    kekkon_rikon が 117 を返すが、正しい結婚・離婚は 390
    2019年に廃止された kagyo_kokei に 295(実体は学業)が入る
  - 2013年度の行は sosu=3988 / kagyo_kokei=95 / kekkon_rikon=310 で定義と一致
  - 検算は両版すべての行で成立(passed == total_rows)。値が壊れていても検出できない
EXPECT
}

cmd_teardown() {
  resolve_names
  echo "以下を削除する:"
  echo "  - Glue テーブル $DB.$TABLE"
  echo "  - Glue データベース $DB"
  echo "  - S3 バケット $BUCKET (中身ごと)"
  read -r -p "続行する? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || {
    echo "中止"
    exit 0
  }
  "${AWS[@]}" glue delete-table --database-name "$DB" --name "$TABLE" 2>/dev/null || true
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
