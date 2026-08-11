# ─────────────────────────────────────────────────────────────────────────────
# 比較対象: 素の構成(汎用バケットに CSV を置いて Glue + Athena で読む)
#
# ここが登壇の主題。同じ2ファイルを同じプレフィックスに置き、テーブル定義は
# 2013-2018 版の 19 列で作る。Athena の CSV テーブルは列を **位置** で読むので、
# 16 列の 2019-2025 版を同じ定義で読むと値が別の列にずれる。
# https://docs.aws.amazon.com/athena/latest/ug/handling-schema-updates-chapter.html
# ─────────────────────────────────────────────────────────────────────────────

locals {
  account_id = data.aws_caller_identity.current.account_id
  raw_bucket = "${var.name_prefix}-raw-${local.account_id}"
  res_bucket = "${var.name_prefix}-athena-results-${local.account_id}"
  glue_db    = replace("${var.name_prefix}_akita", "-", "_")
  csv_prefix = "idouriyuu"
  data_dir   = "${path.module}/../data/akita_idouriyuu"
  csv_objects = {
    "01_kaitousya_2013-2018.csv" = "2013-2018 版(19列 / 11理由)"
    "03_kaitousya_2019-2025.csv" = "2019-2025 版(16列 / 8理由)"
  }
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

# 2ファイルを同じプレフィックスに置く。これが「1つのテーブルとして読める」状態を作る。
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

# ── Glue カタログ ───────────────────────────────────────────────────────────
resource "aws_glue_catalog_database" "akita" {
  name        = local.glue_db
  description = "秋田県オープンデータ(CC BY 4.0)。素の S3+Athena 構成との比較用。"
}

# 列名はローマ字にしている。**日本語のヘッダはそのまま列名にできない**
# (Athena は列名にアンダースコア以外の特殊文字を許さない)。
# CSV は位置で読まれるので、この対応表は人間が頭の中で持つしかない。
# 途中に列が挿入されたときに気づけない理由がここにある。
resource "aws_glue_catalog_table" "idouriyuu_csv" {
  name          = "idouriyuu_csv"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "テーブル定義は 2013-2018 版の19列。2019-2025 版(16列)も同じ定義で読まれる。"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.raw.id}/${local.csv_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"

      parameters = {
        "field.delim"          = ","
        "serialization.format" = ","
      }
    }

    # 識別列(7列)
    columns {
      name = "nengetsubi_code"
      type = "string"
    }
    columns {
      name = "nengetsubi"
      type = "string"
    }
    columns {
      name = "idou_kubun_code"
      type = "string"
    }
    columns {
      name = "idou_kubun"
      type = "string"
    }
    columns {
      name = "danjo_code"
      type = "string"
    }
    columns {
      name = "danjo"
      type = "string"
    }
    columns {
      name = "nenrei_kaikyu"
      type = "string"
    }

    # 総数 + 旧分類の 11 理由。**bigint にしても型では守れない見込み**:
    # ずれて入ってくる値も同じく数値なので型エラーにならない。
    # (実機での確認は未実施。docs/talk-script.md の【要実測】を参照)
    columns {
      name = "sosu"
      type = "bigint"
    }
    columns {
      name = "tenkin"
      type = "bigint"
    }
    columns {
      name = "tengyo_tenshoku"
      type = "bigint"
    }
    columns {
      name = "shushoku"
      type = "bigint"
    }
    columns {
      name = "kagyo_kokei"
      type = "bigint"
    }
    columns {
      name = "shingaku_tenko"
      type = "bigint"
    }
    columns {
      name = "sotsugyo"
      type = "bigint"
    }
    columns {
      name = "kekkon_rikon"
      type = "bigint"
    }
    columns {
      name = "oya_to_dokyo"
      type = "bigint"
    }
    columns {
      name = "ko_mago_to_dokyo"
      type = "bigint"
    }
    columns {
      name = "jutaku_jijo"
      type = "bigint"
    }
    columns {
      name = "sonota"
      type = "bigint"
    }
  }
}

# ── Athena ワークグループ ───────────────────────────────────────────────────
resource "aws_athena_workgroup" "main" {
  name          = var.name_prefix
  description   = "JAWS FESTA 2026 の検証用。スキャン量に上限を設けている。"
  force_destroy = var.force_destroy

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff

    result_configuration {
      output_location = "s3://${aws_s3_bucket.results.id}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}
