# ─────────────────────────────────────────────────────────────────────────────
# Glue: カタログ DB と「素の構成(汎用バケット + CSV)」のテーブル定義。
#
# 扱うデータは「年齢別人口流動調査（県・市町村の年齢各歳、男女別人口）」だけ。
# https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_032
#
# https://docs.aws.amazon.com/athena/latest/ug/handling-schema-updates-chapter.html
# ─────────────────────────────────────────────────────────────────────────────

locals {
  glue_db = replace("${var.name_prefix}_akita", "-", "_")
}

resource "aws_glue_catalog_database" "akita" {
  name        = local.glue_db
  description = "秋田県オープンデータ(CC BY 4.0)。素の S3+Athena 構成との比較用。"
}

# ─────────────────────────────────────────────────────────────────────────────
# drift 検証用のテーブル定義。「データを追加していく中で、参照先のデータが
# 変わってしまう」の検証(S3オブジェクトは s3.tf、クエリは athena.tf)。
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
  drift_nen_head = [
    { name = "nengetsubi_code", type = "string", ja = "年月日コード" },
    { name = "nengetsubi", type = "string", ja = "年月日" },
    { name = "shichoson_code", type = "string", ja = "市町村コード" },
    { name = "shichoson", type = "string", ja = "市町村" },
    { name = "danjo", type = "string", ja = "男女別" },
    { name = "sosu", type = "bigint", ja = "総数" },
  ]
  drift_nen_ages = [
    for i in range(0, 100) : { name = "age_${i}", type = "bigint", ja = "${i}歳" }
  ]
  drift_nen_classes = [
    for i in range(0, 20) : {
      name = "age_cls_${i * 5}_${i * 5 + 4}"
      type = "bigint"
      ja   = "${i * 5}～${i * 5 + 4}歳"
    }
  ]

  # 定義(A): 2015ブロックまでを見て作った128列。位置107に年齢不詳がある。
  drift_nen_cols_128 = concat(
    local.drift_nen_head,
    local.drift_nen_ages,
    [{ name = "age_100_plus", type = "bigint", ja = "100歳以上" }],
    [{ name = "age_unknown", type = "bigint", ja = "年齢不詳(2020ブロックには存在しない)" }],
    local.drift_nen_classes,
  )

  # 定義(B): 2020ブロックを見て作り直した127列。年齢不詳を外しただけ。
  drift_nen_cols_127 = concat(
    local.drift_nen_head,
    local.drift_nen_ages,
    [{ name = "age_100_plus", type = "bigint", ja = "100歳以上" }],
    local.drift_nen_classes,
  )
}

# ── Glue テーブル(A): 年齢各歳を128列の定義で読む ───────────────────────────
# 世代1のデータだけを見て作った定義。世代2でファイルを足しても、この定義は
# 変えない。2020ブロックの行は age_unknown の欄に 0〜4歳 の値を返し、
# 最後の age_cls_95_99 が NULL になる。
#
# パーティション射影は全9ブロックを列挙してある。世代1では2020ブロックの
# ファイルが存在しないので、該当パーティションは単に0行として扱われる。
resource "aws_glue_catalog_table" "drift_nenreikakusai_128" {
  name          = "drift_nenreikakusai_128"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "定義は1980〜2015ブロックの見出し(128列)。年齢不詳が位置107にある前提。"

    "projection.enabled"        = "true"
    "projection.block.type"     = "enum"
    "projection.block.values"   = join(",", local.drift_nen_blocks_all)
    "storage.location.template" = "s3://${aws_s3_bucket.raw.id}/${local.drift_nen_prefix}/block=$${block}/"
  }

  partition_keys {
    name    = "block"
    type    = "string"
    comment = "5年ブロックの先頭年。block='2020' だけが物理127列。"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.raw.id}/${local.drift_nen_prefix}/"
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
      for_each = local.drift_nen_cols_128

      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.ja
      }
    }
  }
}

# ── Glue テーブル(B): 同じデータを127列の定義で読む ─────────────────────────
# 「列が消えたと気づいて定義を作り直した」側。2020ブロックは正しく読めるが、
# 今度は1980〜2015ブロックが1つ右にずれる(age_cls_0_4 に 年齢不詳 の値が入る)。
# CSV のままではどちらの定義でも全期間を正しく読めない、というのがこの対比。
resource "aws_glue_catalog_table" "drift_nenreikakusai_127" {
  name          = "drift_nenreikakusai_127"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "定義は2020ブロックの見出し(127列)。年齢不詳が無い前提。"

    "projection.enabled"        = "true"
    "projection.block.type"     = "enum"
    "projection.block.values"   = join(",", local.drift_nen_blocks_all)
    "storage.location.template" = "s3://${aws_s3_bucket.raw.id}/${local.drift_nen_prefix}/block=$${block}/"
  }

  partition_keys {
    name    = "block"
    type    = "string"
    comment = "5年ブロックの先頭年。"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.raw.id}/${local.drift_nen_prefix}/"
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
      for_each = local.drift_nen_cols_127

      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.ja
      }
    }
  }
}
