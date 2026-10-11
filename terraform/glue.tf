# ─────────────────────────────────────────────────────────────────────────────
# Glue: カタログ DB と「素の構成(汎用バケット + CSV)」のテーブル定義。
#
# 扱うデータは「年齢別人口流動調査（県・市町村の年齢各歳、男女別人口）」
# https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_032
# ─────────────────────────────────────────────────────────────────────────────

locals {
  glue_db = replace("${var.name_prefix}_akita", "-", "_")
}

resource "aws_glue_catalog_database" "akita" {
  name        = local.glue_db
  description = "秋田県オープンデータ(CC BY 4.0)"
}

# ─────────────────────────────────────────────────────────────────────────────
# bronze テーブルの定義。landing を UTF-8(BOMなし)・LF にそろえて構造を確認した CSV を読む。
# 書き出しは notebooks/landing_to_bronze.ipynb(SageMaker Unified Studio で実行)。
# パーティションは切っていない。どのブロックの行かは "$path"(ファイル名の先頭年)で分かる。
#
# 年齢各歳 (050008_toukeika_032) は 2020ブロックで列が1本消える。
#   -> 参照先が物理的にずれる。列名はそのままで中身が隣の列になる。
#
# 手元での期待値は ./scripts/verify_drift.py が出す(Athena の位置読みを再現してある)。
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # ── 年齢各歳の列定義 ──────────────────────────────────────────────────────
  # 物理レイアウト(1980〜2015ブロック・128列):
  #   0-5     年月日コード / 年月日 / 市町村コード / 市町村 / 男女別 / 総数
  #   6-105   0歳 〜 99歳 (各歳100列)
  #   106     100歳以上
  #   107     年齢不詳          <- 2020ブロックではこの列が消える
  #   108-127 0〜4歳 〜 95〜99歳 (5歳階級20列)
  #
  # bronze では全列 string。数値として読めない値(2020ブロックの "-" など)を
  # NULL にせずそのまま残すため。数値への変換と "-" の扱いは silver で決める。
  bronze_nen_head = [
    { name = "nengetsubi_code", type = "string", ja = "年月日コード" },
    { name = "nengetsubi", type = "string", ja = "年月日" },
    { name = "shichoson_code", type = "string", ja = "市町村コード" },
    { name = "shichoson", type = "string", ja = "市町村" },
    { name = "danjo", type = "string", ja = "男女別" },
    { name = "sosu", type = "string", ja = "総数" },
  ]
  bronze_nen_ages = [
    for i in range(0, 100) : { name = "age_${i}", type = "string", ja = "${i}歳" }
  ]
  bronze_nen_classes = [
    for i in range(0, 20) : {
      name = "age_cls_${i * 5}_${i * 5 + 4}"
      type = "string"
      ja   = "${i * 5}～${i * 5 + 4}歳"
    }
  ]

  # 定義(A): 2015ブロックまでを見て作った128列。位置107に年齢不詳がある。
  bronze_nen_cols_128 = concat(
    local.bronze_nen_head,
    local.bronze_nen_ages,
    [{ name = "age_100_plus", type = "string", ja = "100歳以上" }],
    [{ name = "age_unknown", type = "string", ja = "年齢不詳(2020ブロックには存在しない)" }],
    local.bronze_nen_classes,
  )

  # 定義(B): 2020ブロックを見て作り直した127列。年齢不詳を外しただけ。
  bronze_nen_cols_127 = concat(
    local.bronze_nen_head,
    local.bronze_nen_ages,
    [{ name = "age_100_plus", type = "string", ja = "100歳以上" }],
    local.bronze_nen_classes,
  )
}

# ── Glue テーブル(A): 年齢各歳を128列の定義で読む ───────────────────────────
resource "aws_glue_catalog_table" "bronze_nenreikakusai_128" {
  name          = "bronze_nenreikakusai_128"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "定義は1980〜2015ブロックの見出し(128列)。年齢不詳が位置107にある前提。"

  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.lake.id}/${local.bronze_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"

      parameters = {
        "field.delim"          = ","
        "serialization.format" = ","
      }
    }

    dynamic "columns" {
      for_each = local.bronze_nen_cols_128

      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.ja
      }
    }
  }
}

# ── Glue テーブル(B): 同じデータを127列の定義で読む ─────────────────────────
resource "aws_glue_catalog_table" "bronze_nenreikakusai_127" {
  name          = "bronze_nenreikakusai_127"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "定義は2020ブロックの見出し(127列)。年齢不詳が無い前提。"

  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.lake.id}/${local.bronze_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"

      parameters = {
        "field.delim"          = ","
        "serialization.format" = ","
      }
    }

    dynamic "columns" {
      for_each = local.bronze_nen_cols_127

      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.ja
      }
    }
  }
}

# ── Glue テーブル(C): bronze_nenreikakusai_128 と同じ構成 ────────────────────
# 場所・SerDe・列定義(128列・全列 string)は (A) と同一。名前だけ違う。
resource "aws_glue_catalog_table" "bronze_nenreikakusai" {
  name          = "bronze_nenreikakusai"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "定義は1980〜2015ブロックの見出し(128列)。年齢不詳が位置107にある前提。"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.lake.id}/${local.bronze_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"

      parameters = {
        "field.delim"          = ","
        "serialization.format" = ","
      }
    }

    dynamic "columns" {
      for_each = local.bronze_nen_cols_128

      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.ja
      }
    }
  }
}
