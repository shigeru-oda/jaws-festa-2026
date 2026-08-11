# Terraform — 比較する2つの構成を作る

登壇で比べる2つを、同じデータで並べて作る。

| | 作るもの |
| --- | --- |
| **素の構成** | 汎用バケット + CSV 2本 + Glue テーブル(19列定義) + Athena ワークグループ |
| **S3 Tables** | テーブルバケット + 名前空間 + Iceberg テーブル + メンテナンス設定 |

リージョンは `ap-northeast-1`、プロファイルは `default`(どちらも `variables.tf` で変更可)。
S3 Tables が ap-northeast-1 で使えることは 2026-08 時点で確認済み。

## 使う

```sh
aws sso login --profile default   # or aws configure
cd terraform
terraform init
terraform plan
terraform apply
terraform output next_steps       # apply 後の確認手順が出る
```

`terraform validate` は認証情報なしで通る。`plan` 以降はアカウントに触るので
**実行前に何ができるかを把握してから**進めること。

## 何にお金がかかるか

数MBのデータなのでどれも小さいが、**素の構成には無い費目が S3 Tables にはある**。
これが登壇の論点そのものなので、`apply` したら Cost Explorer で実額を見る。

| | 費目 |
| --- | --- |
| 素の構成 | S3 ストレージ + Athena のスキャン量(最小 10MB 課金) + リクエスト |
| S3 Tables | ストレージ + **オブジェクト監視** + **コンパクションのリクエスト/処理** |

事故防止として次を入れてある。

- Athena ワークグループに `bytes_scanned_cutoff_per_query = 1GiB`(`enforce_workgroup_configuration = true`)
- クエリ結果バケットは 7 日で失効(`results_expiration_days`)
- コンパクションは `enable_compaction = false` で切れる

## 片付ける

```sh
terraform destroy
```

`force_destroy = true` が既定なので、テーブル・名前空間・S3 オブジェクトごと消える。
**復旧できない。** 検証用の割り切りなので、本番アカウントで使うなら `false` にする。

## 設計の理由

### Glue テーブルの列名がローマ字になっている

**日本語のヘッダはそのまま Glue の列名にできない。** Athena は列名にアンダースコア以外の
特殊文字を許さない([CREATE TABLE のリファレンス](https://docs.aws.amazon.com/athena/latest/ug/create-table.html))。

つまり `結婚・離婚` → `kekkon_rikon` の対応は**人間が頭の中で持つしかない**。
CSV は列を位置で読むので、途中に列が挿入されても名前側の手がかりが無い。
登壇で話す「静かに間違う」の下地はここにもある。

### 数値列を bigint にしてある

型で守れそうに見えて守れない、という想定を実機で確かめるため。ずれて入ってくる値も
同じく数値なので型エラーにならない見込み。**未検証**なので
`docs/talk-script.md` の【要実測】として残してある。

### Terraform はテーブルを1つしか作らない

`aws_s3tables_table.idouriyuu`(19列)は「Terraform で宣言したスキーマ」と
「テーブル単位のメンテナンス設定」を見せるための固定テーブル。

ノートブック(`notebooks/athena_vs_s3tables.py`)は**同じ名前空間に別のテーブルを
PyIceberg で作り**、2019-2025 版を `union_by_name` で追記して 19列 → 28列 に育てる。
スキーマ進化はデータ側の操作なので、Terraform で書くと逆に不自然になる。

### IAM ポリシーはアタッチしていない

`aws_iam_policy` を2本作るが、どのプリンシパルにも付けていない。実行者に手で付けるか、
管理者権限で動かしているなら不要。**何の権限が必要かを明示するため**に宣言してある。

アクション名は AWS 公式の
[identity-based policies の例](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-identity-based-policies.html)
に合わせた。Glue の Iceberg REST エンドポイント経由にする場合は Lake Formation の
grant が別途必要になることがある。

## プロバイダの書き方でハマった点

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

## 状態ファイル

ローカルの `terraform.tfstate` のまま(`.gitignore` 済み)。検証用に作って消すだけなので
リモートバックエンドは置いていない。
