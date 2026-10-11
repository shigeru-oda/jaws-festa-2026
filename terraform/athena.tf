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
