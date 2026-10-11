# ─────────────────────────────────────────────────────────────────────────────
# 比較対象: 素の構成(汎用バケットに CSV を置いて Glue + Athena で読む)
#
# S3 は s3.tf、Glue カタログは glue.tf に分けている。ここは Athena ワークグループと名前付きクエリ。
#
# https://docs.aws.amazon.com/athena/latest/ug/handling-schema-updates-chapter.html
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# 名前付きクエリ: drift 検証。世代1と世代2で同じものを同じ順に流す。
#   terraform apply -var='drift_generation=1'
#   (drift_01〜drift_04 を流して結果を控える)
#   terraform apply -var='drift_generation=2'
#   (同じクエリを同じ順で流す)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_athena_named_query" "drift_01_loaded_blocks" {
  name        = "drift_01_loaded_blocks"
  description = "世代の確認。block ごとの行数。世代1では 2020 が 0 行。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 世代1: 1980〜2015 の8ブロックに行がある / 2020 は 0 行
    -- 世代2: 2020 ブロックにも 468 行が入る
    SELECT block,
           count(*)                        AS rows_total,
           count(age_unknown)              AS age_unknown_not_null,
           count(age_cls_95_99)            AS last_column_not_null
    FROM ${aws_glue_catalog_database.akita.name}.drift_nenreikakusai_128
    GROUP BY block
    ORDER BY block
  SQL
}

resource "aws_athena_named_query" "drift_02_age_unknown_series" {
  name        = "drift_02_age_unknown_series"
  description = "世代1では2019年までの素直な推移。世代2で2020年以降が3倍に跳ね、以降もっともらしく減り続ける。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 期待値(scripts/verify_drift.py で確認):
    --   2019 = 8,540   <- 本物の年齢不詳
    --   2020 = 25,345  <- 実は 0〜4歳 の値
    --   2021 = 24,136 / 2022 = 22,825 / 2023 = 21,560 / 2024 = 20,201 / 2025 = 18,782
    -- 単調に減るので「不詳が改善した」と読めてしまう。エラーは出ない。
    SELECT substr(nengetsubi, 1, 4) AS nen,
           block,
           age_unknown             AS age_unknown_col,
           age_cls_0_4             AS age_0_4_col,
           age_cls_95_99           AS age_95_99_col
    FROM ${aws_glue_catalog_database.akita.name}.drift_nenreikakusai_128
    WHERE shichoson = '秋田県'
      AND danjo = '男女計（人）'
    ORDER BY nen
  SQL
}

resource "aws_athena_named_query" "drift_03_shift_fingerprint" {
  name        = "drift_03_shift_fingerprint"
  description = "途中の列が消えると最終列が総崩れで NULL になる。世代2で 2020 ブロックだけがそうなる。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 定義より CSV の列が少ないと、余った定義列は NULL になる(例外にはならない)。
    -- 期待値: 世代2で block='2020' だけ null_ratio = 1.0
    SELECT block,
           count(*)                                              AS rows_total,
           count(*) - count(age_cls_95_99)                       AS last_col_null,
           round(1.0 * (count(*) - count(age_cls_95_99)) / count(*), 3) AS null_ratio
    FROM ${aws_glue_catalog_database.akita.name}.drift_nenreikakusai_128
    GROUP BY block
    ORDER BY block
  SQL
}

resource "aws_athena_named_query" "drift_04_two_definitions" {
  name        = "drift_04_two_definitions"
  description = "定義を作り直すと、今度は古いブロックが逆向きにずれる。CSV ではどちらの定義でも全期間を読めない。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 期待値(scripts/verify_drift.py で確認):
    --   128列定義: 2019 の age_cls_0_4 = 26,889(正しい) / 2020 は 31,355(本当は5〜9歳)
    --   127列定義: 2020 の age_cls_0_4 = 25,345(正しい) / 2019 は  8,540(本当は年齢不詳)
    -- 同じ S3 のバイト列を、2つの定義で読んでいる。
    SELECT '128列定義' AS teigi,
           substr(nengetsubi, 1, 4) AS nen,
           age_cls_0_4              AS age_0_4_col,
           age_cls_95_99            AS age_95_99_col
    FROM ${aws_glue_catalog_database.akita.name}.drift_nenreikakusai_128
    WHERE shichoson = '秋田県' AND danjo = '男女計（人）'
      AND substr(nengetsubi, 1, 4) IN ('2019', '2020')
    UNION ALL
    SELECT '127列定義' AS teigi,
           substr(nengetsubi, 1, 4) AS nen,
           age_cls_0_4              AS age_0_4_col,
           age_cls_95_99            AS age_95_99_col
    FROM ${aws_glue_catalog_database.akita.name}.drift_nenreikakusai_127
    WHERE shichoson = '秋田県' AND danjo = '男女計（人）'
      AND substr(nengetsubi, 1, 4) IN ('2019', '2020')
    ORDER BY nen, teigi
  SQL
}
