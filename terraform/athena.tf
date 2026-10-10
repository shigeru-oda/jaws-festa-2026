# ─────────────────────────────────────────────────────────────────────────────
# 比較対象: 素の構成(汎用バケットに CSV を置いて Glue + Athena で読む)
#
# S3 は s3.tf、Glue カタログは glue.tf に分けている。ここは Athena ワークグループのみ。
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
# 名前付きクエリ: 月報人口・世帯。
# Athena コンソールの「保存したクエリ」に並ぶ。apply 後にコンソールを開けば
# そのまま実行できる。登壇のデモ順に 01〜06 の番号を振っている。
#
# 区分コードの構成(2026年版で確認):
#   5000 県計 / 5001 市部計 / 5002 郡部計
#   52xx 市(13) / 53xx・54xx の郡6行 + 町村12行 = 25市町村 + 郡6
# 郡の行は配下の町村の合計なので、全行を SUM すると二重計上になる。
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_athena_named_query" "jks_01_latest_ranking" {
  name        = "jinkousetai_01_最新月の市町村別人口"
  description = "素直な検索の例。最新月の 25 市町村を人口順に並べる。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 最新月(2026年9月1日現在)の市町村別人口・世帯数。
    -- 郡の行は配下の町村の合計なので除外している。
    SELECT kubun            AS shichoson,
           jinko_danjokei   AS jinko,
           setaisu          AS setai,
           jinko_zogen_danjokei AS zengetsu_zogen
    FROM ${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.jinkousetai_csv.name}
    WHERE year = 2026
      AND nengetsubi_code = '2026000901'
      AND kubun_code >= '5200'
      AND kubun NOT LIKE '%郡'
    ORDER BY jinko DESC
  SQL
}

resource "aws_athena_named_query" "jks_02_kenkei_trend" {
  name        = "jinkousetai_02_県計の人口推移_21年分"
  description = "21ファイルを1クエリで横断する。CKAN の DataStore API では出来ない集計。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 県計の 10月1日現在人口を 2006〜2026 で並べる。
    -- CSV 21 本が1つのテーブルとして読めるので UNION を書かずに済む。
    SELECT year,
           max_by(jinko_danjokei, nengetsubi_code) AS jinko_10gatsu,
           count(*)                                AS rows_in_year
    FROM ${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.jinkousetai_csv.name}
    WHERE kubun = '県計'
      AND substr(nengetsubi_code, 7, 2) = '10'
    GROUP BY year
    ORDER BY year
  SQL
}

resource "aws_athena_named_query" "jks_03_rename_is_a_lie" {
  name        = "jinkousetai_03_旧名称の県外転入は合計だった"
  description = "位置20 = 位置23 + 位置24 を 21 年分で検算する。ローカルの実測は 8,119/8,119 一致。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 「県外転入・男女計」(位置20)が「県内転入」(位置23)＋「転入・県外計」(位置24)
    -- と一致するかを年ごとに数える。一致すれば、旧名称は県外転入ではなく合計。
    -- masked は県計行の県内転入が *** で欠測しているぶん(列が bigint なので NULL)。
    SELECT year,
           count(*)                                                     AS rows_total,
           count_if(kengai_tennyu_danjokei
                    = kennai_tennyu_danjokei + tennyu_kengai_kei)        AS matched,
           count_if(kengai_tennyu_danjokei
                    <> kennai_tennyu_danjokei + tennyu_kengai_kei)       AS mismatched,
           count_if(kennai_tennyu_danjokei IS NULL)                      AS masked
    FROM ${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.jinkousetai_csv.name}
    GROUP BY year
    ORDER BY year
  SQL
}

resource "aws_athena_named_query" "jks_04_two_definitions" {
  name        = "jinkousetai_04_同じバイトを2つの定義で読む"
  description = "旧名称テーブルと新名称テーブルで同じ数値が返ることを突き合わせる。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 同じ S3 プレフィックスを、旧名称の定義と新名称の定義で読む。
    -- kyu_kengai_tennyu と shin_tennyu_gokei は必ず一致する(位置が同じ)。
    -- honto_no_kengai が実際の県外転入で、旧名称の値はその 1.8〜2 倍になる。
    SELECT o.nengetsubi,
           o.kubun,
           o.kengai_tennyu_danjokei AS kyu_kengai_tennyu,
           n.tennyu_gokei           AS shin_tennyu_gokei,
           o.tennyu_kengai_kei      AS honto_no_kengai,
           round(
             CAST(o.kengai_tennyu_danjokei AS double)
             / nullif(o.tennyu_kengai_kei, 0), 2)
                                    AS kadai_bairitsu
    FROM ${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.jinkousetai_csv.name} o
    JOIN ${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.jinkousetai_csv_sosu.name} n
      ON o.year = n.year
     AND o.nengetsubi_code = n.nengetsubi_code
     AND o.kubun_code = n.kubun_code
    WHERE o.year = 2020
      AND n.year = 2020
      AND o.kubun = '秋田市'
    ORDER BY o.nengetsubi_code
  SQL
}

resource "aws_athena_named_query" "jks_05_masked_values" {
  name        = "jinkousetai_05_欠測はNULLになる"
  description = "*** の欠測が bigint 列でエラーにならず NULL になることを見る。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 県計の行だけ県内転入・県内転出が *** で欠測している(県内移動を加味しない
    -- ため)。bigint 列なので Athena は例外を投げず NULL を返す。
    -- SUM は NULL を飛ばすので、欠測に気づかないまま合計が出てしまう。
    SELECT year,
           count(*)                                 AS rows_total,
           count(kennai_tennyu_danjokei)            AS kennai_tennyu_not_null,
           count_if(kennai_tennyu_danjokei IS NULL) AS kennai_tennyu_null,
           count_if(kennai_tenshutsu_danjokei IS NULL) AS kennai_tenshutsu_null
    FROM ${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.jinkousetai_csv.name}
    WHERE kubun = '県計'
    GROUP BY year
    ORDER BY year
  SQL
}

resource "aws_athena_named_query" "jks_06_double_count" {
  name        = "jinkousetai_06_郡の行を足すと二重計上になる"
  description = "県計・市部計+郡部計・25市町村合計・全行合計の4通りを並べる。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 同じ1か月を4通りに足す。郡の行は配下の町村の合計なので、
    -- 区分を絞らずに SUM すると町村を二重に数える。
    -- 県計は県内移動を加味していないため 25 市町村の合計とも一致しない(県の注記)。
    SELECT nengetsubi,
           sum(CASE WHEN kubun = '県計' THEN jinko_danjokei END)                       AS kenkei,
           sum(CASE WHEN kubun IN ('市部計', '郡部計') THEN jinko_danjokei END)         AS shibu_gunbu,
           sum(CASE WHEN kubun_code >= '5200' AND kubun NOT LIKE '%郡'
                    THEN jinko_danjokei END)                                           AS shichoson_25,
           sum(jinko_danjokei)                                                         AS zenkou_gokei
    FROM ${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.jinkousetai_csv.name}
    WHERE year = 2026
      AND nengetsubi_code = '2026000901'
    GROUP BY nengetsubi
  SQL
}

# ─────────────────────────────────────────────────────────────────────────────
# 名前付きクエリ: drift 検証。世代1と世代2で同じものを同じ順に流す。
#   terraform apply -var='drift_generation=1'
#   (drift_01〜drift_06 を流して結果を控える)
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

resource "aws_athena_named_query" "drift_05_jinkousetai_label_drift" {
  name        = "drift_05_jinkousetai_label_drift"
  description = "位置が動かないので既存年の集計値は世代2でも変わらない。ずれるのは列名の意味だけ。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 旧名称の列 kengai_tennyu_danjokei(「県外転入・男女計」)は、
    -- 実際には県内＋県外の合計を返し続ける。真の県外計は tennyu_kengai_kei。
    -- 期待値: 世代1 1.77倍 / 世代2で足した年も 1.76倍 (性質が続く)
    SELECT year,
           sum(kengai_tennyu_danjokei) AS labelled_kengai,
           sum(tennyu_kengai_kei)      AS true_kengai,
           round(1.0 * sum(kengai_tennyu_danjokei) / sum(tennyu_kengai_kei), 3) AS ratio
    FROM ${aws_glue_catalog_database.akita.name}.drift_jinkousetai_kyu
    WHERE kubun NOT IN ('県計', '市部計', '郡部計')
      AND kubun NOT LIKE '%郡'
    GROUP BY year
    ORDER BY year
  SQL
}

resource "aws_athena_named_query" "drift_06_jinkousetai_positions" {
  name        = "drift_06_jinkousetai_positions"
  description = "合計 = 県内 + 県外 が全年で成立すれば、列位置は動いていない。"
  workgroup   = aws_athena_workgroup.main.name
  database    = aws_glue_catalog_database.akita.name

  query = <<-SQL
    -- 期待値: mismatched = 0 が全年。欠測は県計の県内転入が *** の行。
    SELECT year,
           count(*) AS rows_total,
           sum(CASE
                 WHEN kengai_tennyu_danjokei IS NULL
                   OR kennai_tennyu_danjokei IS NULL
                   OR tennyu_kengai_kei IS NULL THEN 1 ELSE 0
               END) AS masked,
           sum(CASE
                 WHEN kengai_tennyu_danjokei
                      = kennai_tennyu_danjokei + tennyu_kengai_kei THEN 1 ELSE 0
               END) AS matched,
           sum(CASE
                 WHEN kengai_tennyu_danjokei IS NOT NULL
                  AND kennai_tennyu_danjokei IS NOT NULL
                  AND tennyu_kengai_kei IS NOT NULL
                  AND kengai_tennyu_danjokei
                      <> kennai_tennyu_danjokei + tennyu_kengai_kei THEN 1 ELSE 0
               END) AS mismatched
    FROM ${aws_glue_catalog_database.akita.name}.drift_jinkousetai_kyu
    GROUP BY year
    ORDER BY year
  SQL
}
