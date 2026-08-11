output "region" {
  description = "リソースを作ったリージョン。"
  value       = var.region
}

# ── S3 Tables 側 ────────────────────────────────────────────────────────────
output "table_bucket_arn" {
  description = "テーブルバケットの ARN。PyIceberg の warehouse に渡す値。"
  value       = aws_s3tables_table_bucket.main.arn
}

output "table_bucket_name" {
  description = "テーブルバケット名。"
  value       = aws_s3tables_table_bucket.main.name
}

output "namespace" {
  description = "名前空間。ノートブックもここにテーブルを作る。"
  value       = aws_s3tables_namespace.akita.namespace
}

output "terraform_managed_table" {
  description = "Terraform が宣言した Iceberg テーブル(19列)。ノートブックのテーブルとは別物。"
  value       = "${aws_s3tables_namespace.akita.namespace}.${aws_s3tables_table.idouriyuu.name}"
}

output "s3tables_rest_endpoint" {
  description = <<-EOT
    S3 Tables の Iceberg REST エンドポイント。単一のテーブルバケットを直接読み書きする経路。
    **未検証**: 実際に PyIceberg から繋ぐときにこの URL 形式で通るか確認すること。
  EOT
  value       = "https://s3tables.${var.region}.amazonaws.com/iceberg"
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

output "athena_results_bucket" {
  description = "クエリ結果の置き場。既定 7 日で失効する。"
  value       = aws_s3_bucket.results.id
}

# ── IAM ─────────────────────────────────────────────────────────────────────
output "iam_policy_arns" {
  description = "作成したポリシー。どのプリンシパルにもアタッチしていないので、必要なら手で付ける。"
  value = {
    s3tables     = aws_iam_policy.s3tables_access.arn
    plain_athena = aws_iam_policy.plain_athena_access.arn
  }
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

    # 2) PyIceberg から S3 Tables を触る(ノートブックのカタログ生成を差し替える)
    #    catalog = load_catalog("s3tables", **{
    #        "type": "rest",
    #        "uri": "https://s3tables.${var.region}.amazonaws.com/iceberg",
    #        "warehouse": "${aws_s3tables_table_bucket.main.arn}",
    #        "rest.sigv4-enabled": "true",
    #        "rest.signing-name": "s3tables",
    #        "rest.signing-region": "${var.region}",
    #    })

    # 3) 片付ける(force_destroy = true のままなら中身ごと消える)
    terraform destroy
  EOT
}
