# Terraform — 素の構成(S3 + Glue + Athena)と silver の S3 Tables を作る

素の構成(汎用バケットに CSV を置いて Glue + Athena で読む)と、その silver 層としての
S3 Tables(テーブルバケット上のマネージド Iceberg)を、秋田県オープンデータで作る。

扱うデータは [年齢別人口流動調査（県・市町村の年齢各歳、男女別人口）](https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_032)
(秋田県、CC BY 4.0)。CSV 9本 + bronze の Glue テーブル3本 + silver の S3 Tables 3本を置く。
CSV は `../data/akita_nenreikakusai/` から上げるので、先に `./data/fetch_nenreikakusai.sh` で取得しておく。

| ファイル | 置くもの |
| --- | --- |
| `s3.tf` | データレイク用バケット(`akita/landing/`)・クエリ結果用バケット・CSV オブジェクト |
| `glue.tf` | Glue DB + bronze テーブル3本(128列定義 2本 / 127列定義 1本) |
| `s3tables.tf` | テーブルバケット `<prefix>-silver`・名前空間 `akita`・silver テーブル3本(空のスキーマまで) |
| `athena.tf` | ワークグループ |
| `grant_lakeformation.sh` | silver に Lake Formation の権限を付ける(このアカウントは S3 Tables と Lake Formation の統合が有効) |

silver へのデータの書き込みは Terraform ではなく `../notebooks/bronze_to_silver.ipynb` が行う。

リージョンは `ap-northeast-1`、プロファイルは `default`(どちらも `variables.tf` で変更可)。

## 使う

```sh
aws sso login --profile default   # or aws configure
cd terraform
terraform init
terraform plan
terraform apply
terraform output next_steps   # 確認手順
```

`terraform validate` は認証情報なしで通る。`plan` 以降はアカウントに触るので
**実行前に何ができるかを把握してから**進めること。

## 2つの定義で読み比べる

テーブル定義は `glue.tf`、CSV の配置は `s3.tf`。1980〜2020 の5年ブロック9本を
`akita/landing/population_by_age/` にそのまま置き、同じプレフィックスを2つの bronze テーブルで読む。
パーティションは切っていないので、ブロックは `"$path"` のファイル名(先頭年)で見分ける。

| テーブル | 定義 | 何が起きるか |
| --- | --- | --- |
| `bronze_nenreikakusai_128` | 1980〜2015 の見出し(128列) | 2020 ブロックで参照先が1つ左にずれる |
| `bronze_nenreikakusai_127` | 2020 の見出し(127列) | 逆に 1980〜2015 が1つ右にずれる |

年齢各歳は `年齢不詳` が消える。位置は 0 始まりで数えて 107 で、ここから最後までの
21 列(`年齢不詳` 自身 + 5歳階級 20 列)が1つ左にずれる。位置 106(`100歳以上`)までは
完全に一致する。定義を作り直すと今度は古いブロックが壊れるので、**CSV のままでは
どちらの定義でも全期間を正しく読めない**。これが2テーブル置いてある理由。

秋田県・男女計の行で `age_unknown` 列を年ごとに並べると、こうなる
(2026-10-04 に Athena 上で実測。`out/athena_drift_gen2.json` が生の結果)。

| 年 | `age_unknown` が返す値 | 実際の中身 | `age_cls_95_99` |
| --- | --- | --- | --- |
| 2019 | 8,540 | 年齢不詳(正しい) | 5,059 |
| 2020 | 25,345 | 0〜4歳 | NULL |
| 2021 | 24,136 | 0〜4歳 | NULL |
| 2022 | 22,825 | 0〜4歳 | NULL |
| 2023 | 21,560 | 0〜4歳 | NULL |
| 2024 | 20,201 | 0〜4歳 | NULL |
| 2025 | 18,782 | 0〜4歳 | NULL |

3 倍に跳ねたあと単調に減り続けるので、「不詳の計上が改善した」と読めてしまう。
最終列が全 NULL になるのが唯一の指紋になる
(block=2020 だけ `age_cls_95_99` の NULL 率が 1.0、他の 8 ブロックは 0.0)。

同じ S3 のバイト列を2つの定義で読むと、どちらを選んでも片側が壊れる。

| 定義 | 2019年の `age_cls_0_4` | 2020年の `age_cls_0_4` |
| --- | --- | --- |
| 128列 | 26,889(正しい) | 31,355(実は5〜9歳) |
| 127列 | 8,540(実は年齢不詳) | 25,345(正しい) |

AWS に上げる前の期待値は `./scripts/verify_drift.py` が出す。Athena の読み方
(1行目を捨てる / 位置で突き合わせる / 足りない定義列は NULL / `***` は NULL)を
手元で再現してあるので、クエリ結果が合わない場合は Terraform 側を疑える。
`--check` を付けると期待どおりでなければ非ゼロで落ちる。

### ズレる前とズレた後をその場で見る

同じテーブルの中にズレる前のブロック(1980〜2015)とズレた後のブロック(2020)が
同居しているので、1回の apply のまま確認できる。SQL は
`scripts/sql/` にあり、`--sql` で流す。

```sh
PROF=$(cat terraform/.prof.local)

# (1) 境界を見る。位置106 までは続き、107 から最後までがずれ、最終列が NULL
./scripts/run_athena_queries.py --profile "$PROF" --sql scripts/sql/nen_boundary.sql --tag gen2

# (2) ずれた列の真の中身を127列定義で確定させる
./scripts/run_athena_queries.py --profile "$PROF" --sql scripts/sql/nen_truth.sql --tag gen2

# (3) 定義を直すと痕跡が消えることを測る
./scripts/run_athena_queries.py --profile "$PROF" --sql scripts/sql/nen_fingerprint.sql --tag gen2
```

結果は `out/athena_nen_<名前>_gen2.json` に残る。(1)の実測(秋田県・男女計)。

| 定義の列名 | 2019年 | 2020年 | 2020年に入っている中身 |
| --- | --- | --- | --- |
| `age_100_plus` 位置106 | 617 | 738 | 100歳以上(正しい) |
| `age_unknown` 位置107 | 8,540 | 25,345 | 0〜4歳 |
| `age_cls_0_4` 位置108 | 26,889 | 31,355 | 5〜9歳 |
| `age_cls_90_94` 位置126 | 21,031 | 5,570 | 95〜99歳 |
| `age_cls_95_99` 位置127 | 5,059 | NULL | 対応列なし |

一番目に見える異常は `age_cls_90_94` で、21,031 → 5,570 の -73.5%(真の90〜94歳は
22,248 なので 75% の過小)。年齢階級の人口が1年で4分の1になるのは起こりえないので、
`age_unknown` の3倍跳ねより気づきやすい。

(3)の実測。**定義を127列に直すとズレが無痕跡になる**。

| 定義 | 2015ブロック | 2020ブロック |
| --- | --- | --- |
| 128列 | 390 / 390 正常 | 468 / **0** ← NULL の指紋が出る |
| 127列 | 390 / **390** ← ずれているのに痕跡なし | 468 / 468 正常 |

127列定義が古いブロックを読むと、CSV の128列目(真の95〜99歳 5,059)を受け取る列が
無いので黙って捨てられる。欠けるのではなく余るため NULL が出ない。つまり定義を
新しいほうに合わせて直すと、検知手段のほうが先に失われる。

年齢各歳の CSV は `./data/fetch_nenreikakusai.sh` で取り直す(取得のみ)。
128 列が 8 本・127 列が 1 本・食い違いの開始位置が 107 であることまで検査したい場合は
`./scripts/fetch_nenreikakusai.sh` を使う。

## 何にお金がかかるか

データ総量は約 3.3MB(CSV 9本)なのでどれも小さい。汎用バケット側の費目は S3 ストレージ、
Athena のスキャン量(最小 10MB 課金)、リクエスト。

S3 Tables 側はストレージ・リクエストに加えて、**オブジェクト数に比例する監視の費用が継続して乗る**。
Cost Explorer で 2026-10-01〜10-13 の S3 Tables(東京)は約 0.008 USD
(監視 0.0049 / ストレージ 0.0016 / リクエスト 0.0018)。コンパクションのジョブは走っているが、
まとめる対象が無いので請求は無かった。使わない間は `terraform destroy` で止める。

メンテナンスの設定は Terraform で指定しておらず、既定値のまま(2026-10-13 に確認)。

| 設定 | 単位 | 値 |
| --- | --- | --- |
| コンパクション | テーブル | 有効・目標 512MB・strategy auto |
| スナップショット管理 | テーブル | 有効・保持 120 時間・最小 1 個 |
| 未参照ファイルの削除 | バケット | 有効・未参照 3 日・非現行 10 日 |

事故防止として次を入れてある。

- Athena ワークグループに `bytes_scanned_cutoff_per_query = 1GiB`(`enforce_workgroup_configuration = true`)
- クエリ結果バケットは 7 日で失効(`results_expiration_days`)

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

### bronze の列はすべて string にしてある

bronze は landing を読める形にそろえただけの層なので、型の判断をしない。`bigint` に
すると数値として読めない値が黙って NULL になり、2020ブロックの `-`(40か所)が
bronze で見えなくなる。また列ずれで入ってくる値も数値なので、`bigint` にしても
ずれは防げない。数値への変換(`try_cast`)と `-` の扱いは silver で決める。

### S3 Tables は空のテーブルまでを Terraform で作る

スキーマ進化やデータの入れ替えはデータ側の操作で、Terraform で書くと不自然になる。
Terraform が持つのはテーブルバケット・名前空間・テーブルのスキーマまでで、
データは `bronze_to_silver.ipynb` が Athena の `DELETE` + `INSERT` で書く。
Iceberg 側の挙動の実測は `../scripts/verify_s3tables.py` が、使い捨ての名前空間 `verify` を
作って行い、終わったら消す。

### IAM ポリシーは作らない

admin 権限（または同等のロール）で apply する前提にしてある。以前は
`aws_iam_policy` を宣言だけして**どのプリンシパルにもアタッチしない**形で
「何の権限が必要か」を示していたが、admin で動かすなら実体を作る意味が無いので
2026-10-04 に `iam.tf` ごと外した。

権限を絞ったロールで動かす場合に必要なのは次の4種。これだけ付けば apply と
クエリ実行が通る（`<REGION>` / `<ACCOUNT>` / `<PREFIX>` は環境の値に置き換える）。

| 用途 | アクション | 対象 |
| --- | --- | --- |
| クエリ実行 | `athena:StartQueryExecution` `StopQueryExecution` `GetQueryExecution` `GetQueryResults` `GetWorkGroup` | ワークグループ `<PREFIX>` |
| カタログ読み | `glue:GetDatabase` `GetDatabases` `GetTable` `GetTables` `GetPartition` `GetPartitions` | `catalog` / `database/<PREFIX>_akita` / `table/<PREFIX>_akita/*` |
| CSV 読み | `s3:GetObject` `s3:ListBucket` | `<PREFIX>-<ACCOUNT>-<REGION>-an` とその配下 |
| 結果書き | `s3:GetObject` `PutObject` `AbortMultipartUpload` `ListBucket` `ListBucketMultipartUploads` `ListMultipartUploadParts` | `<PREFIX>-athena-results-<ACCOUNT>` とその配下 |

apply 側には別途 S3 バケット作成・Glue データベース/テーブル作成・Athena
ワークグループ作成の権限が要る。S3 Tables 側には `s3tables:*`(テーブルバケット・名前空間・テーブルの
作成と読み書き)が要る。silver を Athena から読み書きするには、
IAM に加えて Lake Formation の権限が要る(`grant_lakeformation.sh`)。

## プロバイダの書き方でハマった点

### S3 オブジェクトタグの値は「・」と丸括弧を受け付けない

`aws_s3_object` の `tags` に `"月報人口・世帯 2008年 (36列 / UTF-8 BOM / CRLF)"` と
書いたら、PutObject が 39 本まとめて 400 で落ちた。

```
api error InvalidTag: The TagValue you have provided is invalid
```

`terraform validate` も `plan` も通る。apply で初めて分かる。使えるのは英数字・空白と
`+ - = . _ : / @` だけで、日本語の漢字・かなは通るが、全角中黒「・」と丸括弧は
句読点扱いで弾かれる。同じ apply の中で「・」を含まないタグのオブジェクト 8 本だけが
成功していたので、そこから原因を切り分けた。他の AWS リソースのタグより制限がきつい。

## 状態ファイル

ローカルの `terraform.tfstate` のまま(`.gitignore` 済み)。検証用に作って消すだけなので
リモートバックエンドは置いていない。
