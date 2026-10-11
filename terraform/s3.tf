# ─────────────────────────────────────────────────────────────────────────────
# S3: Athena クエリ結果用バケットと、データレイク用バケット(landing)。
#
# 扱うデータは「年齢別人口流動調査（県・市町村の年齢各歳、男女別人口）」
# ─────────────────────────────────────────────────────────────────────────────

locals {
  account_id = data.aws_caller_identity.current.account_id
  res_bucket = "${var.name_prefix}-athena-results-${local.account_id}"
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
# 年齢各歳の CSV。5年ブロック9本(1980〜2015 は128列、2020 だけ127列)。
#
# 出典: 「年齢別人口流動調査（県・市町村の年齢各歳、男女別人口）」(秋田県)
#        秋田県オープンデータカタログサイト, CC BY 4.0
#        https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_032
# 手元への取得は ./data/fetch_nenreikakusai.sh
# ─────────────────────────────────────────────────────────────────────────────

locals {
  nen_data_dir = "${path.module}/../data/akita_nenreikakusai"
  nen_blocks   = ["1980", "1985", "1990", "1995", "2000", "2005", "2010", "2015", "2020"]
}

# ─────────────────────────────────────────────────────────────────────────────
# データレイク用バケット(アカウントリージョン名前空間)と landing 層。bronze テーブル(glue.tf)もここを直接読む。
#
# CKAN から落とした CSV を加工せずそのまま置く。
#   s3://<prefix>-<アカウントID>-<リージョン>-an/akita/landing/population_by_age/
#
# バケットは先に AWS CLI で作ってある(scripts/cmd.md の手順2)ので import で取り込む。
# 名前の末尾 -an はアカウントリージョン名前空間の必須サフィックス。
# 手元への取得は ./data/fetch_nenreikakusai.sh
# ─────────────────────────────────────────────────────────────────────────────

locals {
  lake_bucket    = "${var.name_prefix}-${local.account_id}-${var.region}-an"
  landing_prefix = "akita/landing/population_by_age"
  # bronze は SageMaker Unified Studio のノートブック(notebooks/landing_to_bronze.ipynb)が書く。
  # Terraform はオブジェクトを置かず、Glue テーブルの参照先としてだけ使う。
  bronze_prefix = "akita/bronze/population_by_age"
}

import {
  to = aws_s3_bucket.lake
  id = "${var.name_prefix}-${data.aws_caller_identity.current.account_id}-${var.region}-an"
}

resource "aws_s3_bucket" "lake" {
  bucket           = local.lake_bucket
  bucket_namespace = "account-regional"
  force_destroy    = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "landing_population_by_age" {
  for_each = toset(local.nen_blocks)

  bucket       = aws_s3_bucket.lake.id
  key          = "${local.landing_prefix}/pref_nenreikakusai_${each.value}.csv"
  source       = "${local.nen_data_dir}/pref_nenreikakusai_${each.value}.csv"
  source_hash  = filemd5("${local.nen_data_dir}/pref_nenreikakusai_${each.value}.csv")
  content_type = "text/csv"

  tags = {
    Layer       = "landing"
    Description = "年齢各歳別人口 ${each.value}年からの5年ブロック"
    Source      = "https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_032"
    License     = "CC-BY-4.0"
  }
}
