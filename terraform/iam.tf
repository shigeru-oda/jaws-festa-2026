# ─────────────────────────────────────────────────────────────────────────────
# IAM
#
# ポリシーは作るが**どのプリンシパルにもアタッチしない**。実行者(default
# プロファイルの IAM ユーザー / ロール)に手で付けるか、既に管理者権限で動かして
# いるなら不要。何が必要かを明示するために宣言してある。
#
# アクション名は AWS 公式ドキュメントの例に合わせている:
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-identity-based-policies.html
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "s3tables_access" {
  statement {
    sid    = "AllowTableBucketActions"
    effect = "Allow"

    actions = [
      "s3tables:GetTableBucket",
      "s3tables:ListTables",
      "s3tables:CreateTable",
      "s3tables:PutTableData",
      "s3tables:GetTableData",
      "s3tables:GetTable",
      "s3tables:GetTableMetadataLocation",
      "s3tables:UpdateTableMetadataLocation",
      "s3tables:GetNamespace",
      "s3tables:CreateNamespace",
      "s3tables:ListNamespaces",
    ]

    resources = [
      aws_s3tables_table_bucket.main.arn,
      "${aws_s3tables_table_bucket.main.arn}/table/*",
    ]
  }

  statement {
    sid       = "AllowListTableBuckets"
    effect    = "Allow"
    actions   = ["s3tables:ListTableBuckets"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "s3tables_access" {
  name        = "${var.name_prefix}-s3tables-access"
  description = "PyIceberg から S3 Tables のテーブルを読み書きするための最小権限。"
  policy      = data.aws_iam_policy_document.s3tables_access.json
}

data "aws_iam_policy_document" "plain_athena_access" {
  statement {
    sid    = "AthenaQuery"
    effect = "Allow"

    actions = [
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
    ]

    resources = [aws_athena_workgroup.main.arn]
  }

  statement {
    sid    = "GlueCatalogRead"
    effect = "Allow"

    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
    ]

    resources = [
      "arn:aws:glue:${var.region}:${local.account_id}:catalog",
      "arn:aws:glue:${var.region}:${local.account_id}:database/${aws_glue_catalog_database.akita.name}",
      "arn:aws:glue:${var.region}:${local.account_id}:table/${aws_glue_catalog_database.akita.name}/*",
    ]
  }

  statement {
    sid       = "ReadRawCsv"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.raw.arn, "${aws_s3_bucket.raw.arn}/*"]
  }

  statement {
    sid    = "WriteQueryResults"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:ListMultipartUploadParts",
    ]

    resources = [aws_s3_bucket.results.arn, "${aws_s3_bucket.results.arn}/*"]
  }
}

resource "aws_iam_policy" "plain_athena_access" {
  name        = "${var.name_prefix}-plain-athena-access"
  description = "素の構成(S3 の CSV を Glue + Athena で読む)側の最小権限。"
  policy      = data.aws_iam_policy_document.plain_athena_access.json
}
