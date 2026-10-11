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

output "raw_bucket" {
  description = "CSV を置いた汎用バケット。"
  value       = aws_s3_bucket.raw.id
}

output "athena_workgroup" {
  description = "Athena のワークグループ名。"
  value       = aws_athena_workgroup.main.name
}

output "athena_results_bucket" {
  description = "クエリ結果の置き場。既定 7 日で失効する。"
  value       = aws_s3_bucket.results.id
}

# ── 年齢各歳・男女別人口(050008_toukeika_032) ─────────────────────────────
output "drift_generation" {
  description = "いま S3 に置いてある世代。1 = 列が減る前 / 2 = 追加後。"
  value       = var.drift_generation
}

output "drift_location" {
  description = "年齢各歳 CSV を置いた S3 プレフィックス(block=YYYY/ で区切ってある)。"
  value       = "s3://${aws_s3_bucket.raw.id}/${local.drift_nen_prefix}/"
}

output "drift_loaded" {
  description = "この世代で S3 に置いた5年ブロック。テーブル定義は世代に関わらず固定。"
  value       = local.drift_nen_blocks
}

output "drift_tables" {
  description = <<-EOT
    同じ S3 プレフィックスを指す2つのテーブル。128列定義と127列定義の両方を
    置いてある。どちらを選んでも片側の期間が1列ずれる、という対比のため。
  EOT
  value = {
    nenreikakusai_128 = "${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.drift_nenreikakusai_128.name}"
    nenreikakusai_127 = "${aws_glue_catalog_database.akita.name}.${aws_glue_catalog_table.drift_nenreikakusai_127.name}"
  }
}

output "drift_named_queries" {
  description = "Athena コンソールの「保存したクエリ」に並ぶ名前。デモ順。"
  value = [
    aws_athena_named_query.drift_01_loaded_blocks.name,
    aws_athena_named_query.drift_02_age_unknown_series.name,
    aws_athena_named_query.drift_03_shift_fingerprint.name,
    aws_athena_named_query.drift_04_two_definitions.name,
  ]
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
  }
}

# ── 使い方 ──────────────────────────────────────────────────────────────────
output "next_steps" {
  description = "世代を切り替えて同じクエリを流す手順。"
  value       = <<-EOT
    # 1) 世代1(列が減る前)で apply して、保存したクエリを順に流す
    terraform apply -var='drift_generation=1'

    # 2) Athena コンソールの「保存したクエリ」から drift_01〜drift_04 を実行して控える
    #    https://${var.region}.console.aws.amazon.com/athena/home?region=${var.region}#/query-editor/saved-queries

    # 3) ファイルを足すだけ。テーブル定義は触らない
    terraform apply -var='drift_generation=2'

    # 4) 同じクエリを同じ順で流して突き合わせる
    #    age_unknown が 8,540 -> 25,345 に跳ね、最終列が NULL になる

    # 5) 片付ける(force_destroy = true のままなら中身ごと消える)
    terraform destroy
  EOT
}
