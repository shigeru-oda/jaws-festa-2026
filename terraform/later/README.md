# あとで足す — S3 Tables

ここは **Terraform が読まないディレクトリ**。Terraform はカレントの `*.tf` だけを
読み、サブディレクトリには降りないので、`later/s3tables.tf` は置いてあっても
`validate` / `plan` / `apply` の対象にならない。モジュールでもない(誰も参照していない)。

## なぜ外してあるか

一度に扱う情報量を減らすため。素の構成(S3 + Glue + Athena)で「列が変わると
参照先がずれる」ことを先に確定させ、理解できたところで S3 Tables 側を足す。
2026-10-04 に `terraform/s3tables.tf` から移動した。

副作用として、テーブルバケットのオブジェクト監視による継続課金も止まっている。

## 戻す手順

### 1. ファイルを戻す

```sh
cd ~/Documents/github/jaws-festa-2026/terraform
git mv later/s3tables.tf s3tables.tf
```

このファイルは `count` ゲートの無い原形。段階的に読むなら、上から
テーブルバケット → 名前空間 → テーブル(スキーマ19列 + メンテナンス設定)の順で
3リソースだけなので、そのまま読み下せる。

### 2. 変数を4つ戻す

`variables.tf` の末尾に貼る。

```hcl
variable "namespace" {
  description = "S3 Tables の名前空間。小文字・数字・アンダースコアのみ。"
  type        = string
  default     = "akita"
}

variable "table_name" {
  description = "Terraform が作る Iceberg テーブル名。ノートブックは別テーブルを PyIceberg で作る。"
  type        = string
  default     = "idouriyuu_tf"
}

variable "enable_compaction" {
  description = <<-EOT
    テーブルの自動コンパクションを有効にするか。
    数MBのデータでは出番が無い(登壇で示す論点そのもの)が、
    設定の存在と既定値を見せるために明示的に書いてある。
  EOT
  type        = bool
  default     = true
}

variable "target_file_size_mb" {
  description = "コンパクションの目標ファイルサイズ(MB)。64〜512。"
  type        = number
  default     = 64

  validation {
    condition     = var.target_file_size_mb >= 64 && var.target_file_size_mb <= 512
    error_message = "target_file_size_mb は 64〜512 の範囲にしてください。"
  }
}
```

### 3. IAM ポリシーを戻す(任意)

どのプリンシパルにもアタッチしない宣言用。管理者権限で動かしているなら不要。
`iam.tf` に貼る。

```hcl
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
```

アクション名は AWS 公式の
[identity-based policies の例](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-identity-based-policies.html)
に合わせたもの。

### 4. output を戻す(任意)

`outputs.tf` に貼る。`table_bucket_arn` は PyIceberg の `warehouse` に渡す値。

```hcl
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
  description = "S3 Tables の Iceberg REST エンドポイント。単一のテーブルバケットを直接読み書きする経路。"
  value       = "https://s3tables.${var.region}.amazonaws.com/iceberg"
}
```

`iam_policy_arns` の map に 1 行足す場合はこれ。

```hcl
    s3tables = aws_iam_policy.s3tables_access.arn
```

### 5. 確認する

```sh
terraform fmt -recursive
terraform validate
terraform plan -var="profile=$(cat .prof.local)"
```

増えるリソースは4本(テーブルバケット / 名前空間 / テーブル / IAM ポリシー)。
`apply` すると、そこから先はオブジェクト監視が継続課金になる。

## 戻す前に知っておくこと

### プロバイダの記法が素の構成と違う

`aws_s3tables_*` は Plugin Framework 実装なので、`encryption_configuration` と
`maintenance_configuration` は**ブロックではなく属性**として書く(`= { ... }`)。
公式ドキュメントの例はブロック記法に見えるが、provider 6.58.0 では通らない。

```hcl
# NG
maintenance_configuration {
  iceberg_compaction { ... }
}

# OK
maintenance_configuration = {
  iceberg_compaction = { ... }
}
```

`encryption_configuration` は `sse_algorithm = "AES256"` でも `kms_key_arn` の指定が
必須(= `null`)。一方 `aws_s3tables_table` の `metadata` はブロック記法で書く。
同じリソース群の中で記法が混ざるので、`terraform validate` で確かめながら書くのが早い。

### テーブル削除は取り消せない

`terraform destroy` でテーブルバケットごと消える(`force_destroy = true` のため)。
中にデータを入れてから消すと戻せない。2026-10-04 に一度 apply して削除したときは、
Terraform が作った空テーブル1本だけだったので失うものが無かった。

### PyIceberg でデータを入れる場合

`notebooks/` は計測を AWS 上に寄せたため 2026-10-04 に削除した。ローカルカタログで
Iceberg を触っていたコードは git 履歴にある。

```sh
git show 64c9f75:notebooks/akita_iceberg.py        > /tmp/akita_iceberg.py
git show 64c9f75:notebooks/athena_vs_s3tables.py   > /tmp/athena_vs_s3tables.py
```

どちらも `file://work/warehouse` のローカルカタログにテーブルを作る作りなので、
S3 Tables に向けるならカタログ生成をこう差し替える。

```python
catalog = load_catalog("s3tables", **{
    "type": "rest",
    "uri": "https://s3tables.ap-northeast-1.amazonaws.com/iceberg",
    "warehouse": "<terraform output table_bucket_arn の値>",
    "rest.sigv4-enabled": "true",
    "rest.signing-name": "s3tables",
    "rest.signing-region": "ap-northeast-1",
})
```

この差し替えは未検証。REST エンドポイントの URL 形式で実際に通るかは確認が必要。
