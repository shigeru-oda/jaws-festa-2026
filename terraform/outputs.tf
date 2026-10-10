output "region" {
  description = "リソースを作ったリージョン。"
  value       = var.region
}

output "glue_rest_endpoint" {
  description = <<-EOT
    Glue 経由の Iceberg REST エンドポイント。複数エンジンでカタログを統一したい場合の経路。
    Lake Formation の grant が別途必要になることがある。
  EOT
  value       = "https://glue.${var.region}.amazonaws.com/iceberg"
}

# ── 素の構成側 ──────────────────────────────────────────────────────────────
output "raw_bucket" {
  description = "CSV を置いた汎用バケット。"
  value       = aws_s3_bucket.raw.id
}

output "csv_location" {
  description = "Glue テーブルが指している S3 プレフィックス(2ファイルが入っている)。"
  value       = "s3://${aws_s3_bucket.raw.id}/${local.csv_prefix}/"
}

output "glue_table" {
  description = "Athena から引くテーブル。定義は 2013-2018 版の19列。"
  value       = "${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.idouriyuu_csv.name}"
}

output "athena_workgroup" {
  description = "Athena のワークグループ名。"
  value       = aws_athena_workgroup.main.name
}

# ── 月報人口・世帯(050008_toukeika_031) ────────────────────────────────────
output "jinkousetai_location" {
  description = "月報人口 CSV 21 本を置いた S3 プレフィックス(year=YYYY/ で区切ってある)。"
  value       = "s3://${aws_s3_bucket.raw.id}/${local.jks_prefix}/"
}

output "jinkousetai_tables" {
  description = <<-EOT
    同じ S3 プレフィックスを指す2つの Glue テーブル。列の位置は同一で、
    列名だけが違う(26 列)。どちらで読んでも Athena はエラーを出さない。
  EOT
  value = {
    kyumei  = "${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.jinkousetai_csv.name}"
    shinmei = "${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.jinkousetai_csv_sosu.name}"
  }
}

output "jinkousetai_facts" {
  description = "テーブルを作る前にローカル CSV で実測した値。apply 後の Athena 結果と突き合わせる。"
  value = {
    years          = "${local.jks_years[0]}-${local.jks_years[length(local.jks_years) - 1]}"
    files          = length(local.jks_years)
    columns        = length(local.jks_columns)
    renamed        = local.jks_renamed_count
    kyumei_years   = "2008-2023 (16年)"
    shinmei_years  = "2006-2007, 2024-2026 (5年)"
    rows_per_month = 34
    rows_total     = 8364
  }
}

output "jinkousetai_named_queries" {
  description = "Athena コンソールの「保存したクエリ」に並ぶ名前。デモ順。"
  value = [
    aws_athena_named_query.jks_01_latest_ranking.name,
    aws_athena_named_query.jks_02_kenkei_trend.name,
    aws_athena_named_query.jks_03_rename_is_a_lie.name,
    aws_athena_named_query.jks_04_two_definitions.name,
    aws_athena_named_query.jks_05_masked_values.name,
    aws_athena_named_query.jks_06_double_count.name,
  ]
}

output "jinkousetai_next_steps" {
  description = "apply 後にそのまま実行できる確認手順(月報人口側)。"
  value       = <<-EOT
    # 1) 旧名称の「県外転入」が県内＋県外の合計であることを 21 年分で検算する
    aws athena start-query-execution \
      --profile ${var.profile} --region ${var.region} \
      --work-group ${aws_athena_workgroup.main.name} \
      --query-string "SELECT year, count(*) AS rows_total,
                             count_if(kengai_tennyu_danjokei
                                      = kennai_tennyu_danjokei + tennyu_kengai_kei) AS matched
                      FROM ${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.jinkousetai_csv.name}
                      GROUP BY year ORDER BY year"

    # 期待値(ローカル CSV での実測): 不一致 0、一致 8,119、欠測 245。
    # 2006 と 2026 は年の途中までなので rows_total が 306、他は 408。

    # 2) 同じバイト列を2つの定義で読んで、数値が一致することを見る
    #    コンソールの「保存したクエリ」に 01〜06 が入っているのでそこから実行できる。
    #    https://${var.region}.console.aws.amazon.com/athena/home?region=${var.region}#/query-editor/saved-queries

    # 3) 1年ぶんだけスキャンする(パーティション射影が効いているか)
    #    WHERE year = 2020 を付けた場合のスキャン量が 65KB 前後に収まる。
  EOT
}

# ── 参照先ドリフトの検証(athena_drift.tf) ──────────────────────────────────
output "drift_generation" {
  description = "いま S3 に置いてある世代。1 = 列が減る前 / 2 = 追加後。"
  value       = var.drift_generation
}

output "drift_loaded" {
  description = "この世代で S3 に置いたファイル。テーブル定義は世代に関わらず固定。"
  value = {
    nenreikakusai_blocks = local.drift_nen_blocks
    jinkousetai_years    = "${local.drift_jks_years[0]}-${local.drift_jks_years[length(local.drift_jks_years) - 1]} (${length(local.drift_jks_years)}本)"
  }
}

output "drift_tables" {
  description = <<-EOT
    同じ S3 プレフィックスを指す3つのテーブル。年齢各歳は128列定義と127列定義の
    両方を置いてある。どちらを選んでも片側の期間が1列ずれる、という対比のため。
  EOT
  value = {
    nenreikakusai_128 = "${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.drift_nenreikakusai_128.name}"
    nenreikakusai_127 = "${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.drift_nenreikakusai_127.name}"
    jinkousetai_kyu   = "${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.drift_jinkousetai_kyu.name}"
  }
}

output "drift_expected" {
  description = <<-EOT
    scripts/verify_drift.py がローカル CSV で出した期待値。
    Athena の結果がここと食い違ったら、読み方の再現かテーブル定義のどちらかが違う。
  EOT
  value = {
    nenrei_2019_age_unknown = "8540 (本物の年齢不詳)"
    nenrei_2020_age_unknown = "25345 (実際は 0〜4歳 の値)"
    nenrei_2020_last_column = "NULL (列削除の指紋)"
    nenrei_127def_2019      = "age_cls_0_4 = 8540 (実際は年齢不詳。逆向きにずれる)"
    jks_ratio_gen1          = "1.773 (旧名称の県外転入 / 真の県外計)"
    jks_ratio_gen2_added    = "1.763 (足した年でも同じ性質)"
    jks_values_change       = "変わらない (位置が動かないため)"
  }
}

output "drift_next_steps" {
  description = "世代を切り替えて同じクエリを流す手順。"
  value       = <<-EOT
    # 1) 世代1(列が減る前)で apply して、保存したクエリを順に流す
    terraform apply -var='drift_generation=1'

    # 2) Athena コンソールの「保存したクエリ」から drift_01〜drift_06 を実行して控える
    #    https://${var.region}.console.aws.amazon.com/athena/home?region=${var.region}#/query-editor/saved-queries

    # 3) ファイルを足すだけ。テーブル定義は触らない
    terraform apply -var='drift_generation=2'

    # 4) 同じクエリを同じ順で流して突き合わせる
    #    年齢各歳: age_unknown が 8,540 -> 25,345 に跳ね、最終列が NULL になる
    #    月報:     既存年の数値は1つも変わらない。ずれるのは列名の意味だけ

    # ローカルでの期待値は AWS 不要で確認できる
    ./scripts/verify_drift.py --check
  EOT
}

output "athena_results_bucket" {
  description = "クエリ結果の置き場。既定 7 日で失効する。"
  value       = aws_s3_bucket.results.id
}

# ── 使い方 ──────────────────────────────────────────────────────────────────
output "next_steps" {
  description = "apply 後にそのまま実行できる確認手順。"
  value       = <<-EOT
    # 1) 素の構成で「静かに間違う」ことを実機で確認する
    aws athena start-query-execution \
      --profile ${var.profile} --region ${var.region} \
      --work-group ${aws_athena_workgroup.main.name} \
      --query-string "SELECT nengetsubi, kekkon_rikon, jutaku_jijo, sonota
                      FROM ${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.idouriyuu_csv.name}
                      WHERE idou_kubun = '県外転入' AND danjo = '男女計' AND nenrei_kaikyu = '総数'
                      ORDER BY nengetsubi_code"

    # 2019 年度の行で kekkon_rikon が 117(本当は 390)、jutaku_jijo と sonota が NULL に
    # なっていれば、ローカルの DuckDB による再現と一致する。

    # 2) 片付ける(force_destroy = true のままなら中身ごと消える)
    terraform destroy
  EOT
}
