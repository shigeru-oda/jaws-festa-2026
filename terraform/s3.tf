# ─────────────────────────────────────────────────────────────────────────────
# S3: 生データ用バケットと Athena クエリ結果用バケット。
#
# drift 検証用・月報人口世帯用の CSV オブジェクトも aws_s3_bucket.raw を
# 再利用する(バケットは新設しない)。テーブル定義は glue.tf、名前付きクエリは
# athena.tf 側にある。
# ─────────────────────────────────────────────────────────────────────────────

locals {
  account_id = data.aws_caller_identity.current.account_id
  raw_bucket = "${var.name_prefix}-raw-${local.account_id}"
  res_bucket = "${var.name_prefix}-athena-results-${local.account_id}"
}

# ── 生データ用の汎用バケット ────────────────────────────────────────────────
resource "aws_s3_bucket" "raw" {
  bucket        = local.raw_bucket
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "csv" {
  for_each = local.csv_objects

  bucket      = aws_s3_bucket.raw.id
  key         = "${local.csv_prefix}/${each.key}"
  source      = "${local.data_dir}/${each.key}"
  source_hash = filemd5("${local.data_dir}/${each.key}")

  tags = {
    Description = each.value
  }
}

# ── Athena のクエリ結果用バケット ──────────────────────────────────────────
resource "aws_s3_bucket" "results" {
  bucket        = local.res_bucket
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "expire-query-results"
    status = "Enabled"

    filter {}

    expiration {
      days = var.results_expiration_days
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 月報人口・世帯(年齢別人口流動調査 月報バックナンバーデータ)の CSV。
#
# 出典: 「年齢別人口流動調査（月報バックナンバーデータ）」(秋田県)
#        秋田県オープンデータカタログサイト, CC BY 4.0
#        https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_031
#
# 2006〜2026 年の 21 ファイル・全 36 列。year=YYYY/ のレイアウトにする。
# Hive 形式なのでパーティション射影が使え、ALTER TABLE ADD PARTITION も
# MSCK REPAIR も要らない。テーブル定義は glue.tf、クエリは athena.tf 参照。
# ─────────────────────────────────────────────────────────────────────────────

locals {
  jks_prefix   = "jinkousetai"
  jks_data_dir = "${path.module}/../data/akita_jinkousetai"
  jks_years    = [for y in range(2006, 2027) : tostring(y)]
}

resource "aws_s3_object" "jinkousetai" {
  for_each = toset(local.jks_years)

  bucket      = aws_s3_bucket.raw.id
  key         = "${local.jks_prefix}/year=${each.value}/050008_jinkousetai_${each.value}.csv"
  source      = "${local.jks_data_dir}/050008_jinkousetai_${each.value}.csv"
  source_hash = filemd5("${local.jks_data_dir}/050008_jinkousetai_${each.value}.csv")

  tags = {
    # タグ値に「・」や丸括弧は入れられない(InvalidTag)。
    Description = "月報人口 世帯 ${each.value}年 36列 UTF-8BOM CRLF"
    Source      = "https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_031"
    License     = "CC-BY-4.0"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# drift 検証用の CSV。「データを追加していく中で、参照先のデータが変わって
# しまう」の検証(テーブル定義は glue.tf、クエリは athena.tf)。
#
# var.drift_generation で置くファイルの世代を切り替える。テーブル定義は
# 一度も触らない。同じクエリを世代1と世代2で流して突き合わせる。
#
#   terraform apply -var='drift_generation=1'   # 列が減る前
#   terraform apply -var='drift_generation=2'   # ファイルを足すだけ
#
# 題材は年齢別人口流動調査の2つの表。同じ調査なのに壊れ方が違う。
#
#   年齢各歳 (050008_toukeika_032) : 2020ブロックで列が1本消える
#   月報     (050008_toukeika_031) : 2024年で26列の名前が変わる
#
# 出典: 「年齢別人口流動調査」(秋田県) 秋田県オープンデータカタログサイト, CC BY 4.0
#        https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_032
#        https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_031
# ─────────────────────────────────────────────────────────────────────────────

locals {
  drift_nen_prefix   = "drift/nenreikakusai"
  drift_jks_prefix   = "drift/jinkousetai"
  drift_nen_data_dir = "${path.module}/../data/akita_nenreikakusai"
  drift_jks_data_dir = "${path.module}/../data/akita_jinkousetai"

  # 年齢各歳は5年ブロック配布。ファイル名は先頭年。
  drift_nen_blocks_all  = ["1980", "1985", "1990", "1995", "2000", "2005", "2010", "2015", "2020"]
  drift_nen_blocks_gen1 = slice(local.drift_nen_blocks_all, 0, 8) # 1980〜2015(すべて128列)
  drift_nen_blocks      = var.drift_generation == 1 ? local.drift_nen_blocks_gen1 : local.drift_nen_blocks_all

  # 月報は1年1本。世代1は旧名称だけに絞る。
  drift_jks_years_all  = [for y in range(2006, 2027) : tostring(y)]
  drift_jks_years_gen1 = [for y in range(2008, 2024) : tostring(y)]
  drift_jks_years      = var.drift_generation == 1 ? local.drift_jks_years_gen1 : local.drift_jks_years_all
}

resource "aws_s3_object" "drift_nenreikakusai" {
  for_each = toset(local.drift_nen_blocks)

  bucket      = aws_s3_bucket.raw.id
  key         = "${local.drift_nen_prefix}/block=${each.value}/pref_nenreikakusai_${each.value}.csv"
  source      = "${local.drift_nen_data_dir}/pref_nenreikakusai_${each.value}.csv"
  source_hash = filemd5("${local.drift_nen_data_dir}/pref_nenreikakusai_${each.value}.csv")

  tags = {
    Description = "年齢各歳別人口 ${each.value}年からの5年ブロック"
    Source      = "https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_032"
    License     = "CC-BY-4.0"
    # Generation タグは置かない。置くと世代を切り替えるたびに既存オブジェクト全部が
    # タグ更新で "change" に入り、「ファイルを足しただけ」が plan 上で見えなくなる。
    # いま何が載っているかは drift_01 がデータ側から答える。
  }
}

resource "aws_s3_object" "drift_jinkousetai" {
  for_each = toset(local.drift_jks_years)

  bucket      = aws_s3_bucket.raw.id
  key         = "${local.drift_jks_prefix}/year=${each.value}/050008_jinkousetai_${each.value}.csv"
  source      = "${local.drift_jks_data_dir}/050008_jinkousetai_${each.value}.csv"
  source_hash = filemd5("${local.drift_jks_data_dir}/050008_jinkousetai_${each.value}.csv")

  tags = {
    # タグ値に「・」や丸括弧は入れられない(InvalidTag)。
    Description = "月報人口 世帯 ${each.value}年"
    Source      = "https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_031"
    License     = "CC-BY-4.0"
    # Generation タグは置かない(理由は drift_nenreikakusai と同じ)。
  }
}
