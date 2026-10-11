# ─────────────────────────────────────────────────────────────────────────────
# silver 層: S3 Tables(マネージド Iceberg)。
#
# bronze の Glue テーブル3本(glue.tf)に合わせて、同じ名前・同じ列で3本作る。
#
#   bronze (Glue / CSV)            silver (S3 Tables / Iceberg)
#   bronze_nenreikakusai      ->   silver_nenreikakusai      (128列)
#   bronze_nenreikakusai_128  ->   silver_nenreikakusai_128  (128列)
#   bronze_nenreikakusai_127  ->   silver_nenreikakusai_127  (127列)
#
# bronze は全列 string。silver で型を決める: 識別列5本は string、人数の列は long。
# "-" など数値にならない値の扱いは、bronze -> silver の変換処理で決める。
#
# Terraform が作るのは空のテーブル(スキーマ)まで。データの書き込みは別の処理が行う。
# Athena からは s3tablescatalog/<テーブルバケット名> カタログとして見える
# (このアカウントは S3 Tables と Lake Formation の統合が有効)。
#
# 記法の注意(later/README.md 参照): encryption_configuration / maintenance_configuration
# は属性(= { ... })、metadata はブロックで書く。
# ─────────────────────────────────────────────────────────────────────────────

locals {
  silver_namespace = "akita"

  # 識別列。これ以外(総数・各歳・100歳以上・年齢不詳・5歳階級)は人数なので long。
  silver_string_columns = ["nengetsubi_code", "nengetsubi", "shichoson_code", "shichoson", "danjo"]

  silver_tables = {
    silver_nenreikakusai     = local.bronze_nen_cols_128
    silver_nenreikakusai_128 = local.bronze_nen_cols_128
    silver_nenreikakusai_127 = local.bronze_nen_cols_127
  }
}

resource "aws_s3tables_table_bucket" "silver" {
  name          = "${var.name_prefix}-silver"
  force_destroy = var.force_destroy

  encryption_configuration = {
    sse_algorithm = "AES256"
    kms_key_arn   = null # SSE-S3 なので KMS キーは使わない
  }
}

resource "aws_s3tables_namespace" "akita" {
  namespace        = local.silver_namespace
  table_bucket_arn = aws_s3tables_table_bucket.silver.arn
}

resource "aws_s3tables_table" "silver" {
  for_each = local.silver_tables

  name             = each.key
  namespace        = aws_s3tables_namespace.akita.namespace
  table_bucket_arn = aws_s3tables_namespace.akita.table_bucket_arn
  format           = "ICEBERG"

  metadata {
    iceberg {
      schema {
        dynamic "field" {
          for_each = each.value

          content {
            name = field.value.name
            type = contains(local.silver_string_columns, field.value.name) ? "string" : "long"
          }
        }
      }
    }
  }
}

output "silver_tables" {
  description = "silver 層の S3 Tables。Athena では \"s3tablescatalog/<バケット名>\".akita.<テーブル名> で引く。"
  value = {
    table_bucket_arn = aws_s3tables_table_bucket.silver.arn
    catalog          = "s3tablescatalog/${aws_s3tables_table_bucket.silver.name}"
    namespace        = aws_s3tables_namespace.akita.namespace
    tables           = sort([for t in aws_s3tables_table.silver : t.name])
  }
}
