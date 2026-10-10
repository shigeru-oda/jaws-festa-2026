# Terraform — 素の構成(S3 + Glue + Athena)を作る

素の構成(汎用バケットに CSV を置いて Glue + Athena で読む)を、秋田県オープンデータで作る。

S3 Tables 側はこの Terraform では**あとで足す**。一度に扱う情報量を減らすため、
まず素の構成で「列が変わると参照先がずれる」ことを確定させ、理解できたところで
S3 Tables を足す。コードは消しておらず [`later/`](later/) に原形で置いてある
(Terraform はサブディレクトリを読まないので `validate` / `plan` の対象外)。
戻す手順・必要な変数・output・プロバイダ記法の注意は [`later/README.md`](later/README.md)。

副作用として、テーブルバケットのオブジェクト監視による継続課金も止まっている。

素の構成には3つのデータセットが載っている。

| ファイル | データセット | 置くもの |
| --- | --- | --- |
| `athena_jinkousetai.tf` | [年齢別人口流動調査（月報バックナンバー）](https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_031) | CSV 21本(2006〜2026) + Glue テーブル2本 + 名前付きクエリ6本 |
| `athena_plain.tf` | 人口移動理由実態調査 | CSV 2本 + Glue テーブル1本(19列定義) + バケット・DB・ワークグループ |
| `athena_drift.tf` | [同（年齢各歳）](https://ckan.pref.akita.lg.jp/dataset/050008_toukeika_032) ＋ 月報 | CSV 最大30本 + Glue テーブル3本 + 名前付きクエリ6本 |

リージョンは `ap-northeast-1`、プロファイルは `default`(どちらも `variables.tf` で変更可)。

## 使う

```sh
aws sso login --profile default   # or aws configure
cd terraform
terraform init
terraform plan
terraform apply
terraform output next_steps              # 人口移動理由側の確認手順
terraform output jinkousetai_next_steps  # 月報人口側の確認手順
```

`terraform validate` は認証情報なしで通る。`plan` 以降はアカウントに触るので
**実行前に何ができるかを把握してから**進めること。

## 月報人口・世帯を Athena で検索する

CSV 21 本を `s3://<raw>/jinkousetai/year=YYYY/` に置き、同じプレフィックスを指す
Glue テーブルを2本作る。**列の位置は 36 列すべて同一で、列名だけが 26 列違う**。

| テーブル | 列名の出どころ | 該当年 |
| --- | --- | --- |
| `jinkousetai_csv` | 「人口・男女計」「県外転入・男女計」系 | 2008〜2023 (16年) |
| `jinkousetai_csv_sosu` | 「人口・総数」「転入・合計」系 | 2006〜2007, 2024〜2026 (5年) |

2024 年の改称は一方向の変更ではない。同じ日に投入された 21 本の中で、
2006〜2007 は既に新名称、2008〜2023 が旧名称、2024 以降が新名称に戻っている。
どちらの定義を選んでも 5年分か 16年分が見出しと食い違う。

位置が動かないので、どちらのテーブルでも Athena は全 21 年をエラーなしで読み、
返る数値も一致する。壊れるのは列名が指している意味のほうで、旧名称の
`kengai_tennyu_danjokei`(県外転入・男女計)は実際には県内＋県外の合計になっている。

```
位置20(県外転入・男女計) = 位置23(県内転入) + 位置24(転入・県外計)
→ 21年分 8,119 行すべてで成立(不一致 0 / 欠測 245)
```

欠測 245 は県計の行で県内転入・県内転出が `***` になっているぶん(県内移動を
加味しない県の仕様)。bigint 列なので Athena は例外を投げず NULL を返す。

パーティションは射影で解いている(`projection.enabled = true`、`year` を 2006〜2026 の
整数レンジ)。ファイルを置き足しても `ALTER TABLE ADD PARTITION` も
`MSCK REPAIR TABLE` も要らない。`WHERE year = 2020` でスキャンは 1 ファイルに絞られる。

Athena コンソールの「保存したクエリ」に 6 本入る。デモの順番そのまま。

| 名前 | 見せること |
| --- | --- |
| `jinkousetai_01_最新月の市町村別人口` | 素直な検索。郡の行を除いた 25 市町村を人口順に |
| `jinkousetai_02_県計の人口推移_21年分` | 21 ファイルを 1 クエリで横断する(CKAN の DataStore では出来ない) |
| `jinkousetai_03_旧名称の県外転入は合計だった` | 位置20 = 位置23 + 位置24 を年ごとに検算 |
| `jinkousetai_04_同じバイトを2つの定義で読む` | 2 テーブルを JOIN して同値であることを突き合わせる |
| `jinkousetai_05_欠測はNULLになる` | `***` が bigint 列で黙って NULL になる |
| `jinkousetai_06_郡の行を足すと二重計上になる` | 区分を絞らない SUM が町村を二重に数える |

CSV を取り直すときは `./scripts/fetch_jinkousetai.sh`(CKAN Action API、認証不要)。
取得後に列数・BOM・恒等式を検査して、原稿の主張と食い違ったら非ゼロで落ちる。
`--check` だけ付けると取得せず手元のファイルを検査する。

## データを足すと参照先が変わるかを測る

テーブル定義は `glue.tf`、保存クエリは `athena.tf`、CSV の配置は `s3.tf`。
`var.drift_generation` で S3 に置くファイルの世代だけを切り替える。
**テーブル定義は一度も触らない**ので、結果が変わったらそれはデータ追加だけが原因。

| 世代 | 年齢各歳 (5年ブロック) | 月報 (1年1本) |
| --- | --- | --- |
| 1 | 1980〜2015 の 8 本(すべて 128 列) | 2008〜2023 の 16 本(旧名称) |
| 2 | +2020 ブロック(**127 列**) | +2006, 2007, 2024〜2026(新名称) |

```sh
terraform apply -var='drift_generation=1'
# Athena の保存したクエリ drift_01〜drift_06 を順に流して結果を控える
terraform apply -var='drift_generation=2'
# 同じクエリを同じ順で流して突き合わせる
```

題材は同じ年齢別人口流動調査の2つの表で、壊れ方が違う。

| テーブル | 定義 | 世代2で何が起きるか |
| --- | --- | --- |
| `drift_nenreikakusai_128` | 1980〜2015 の見出し(128列) | 2020 ブロックで参照先が1つ左にずれる |
| `drift_nenreikakusai_127` | 2020 の見出し(127列) | 逆に 1980〜2015 が1つ右にずれる |
| `drift_jinkousetai_kyu` | 2008〜2023 の見出し(旧名称36列) | 値は1つも動かない。名前の意味だけずれる |

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
最終列が全 NULL になるのが唯一の指紋で、`drift_03` がそれを数える
(block=2020 だけ `null_ratio = 1.0`、他の 8 ブロックは `0.0`)。

`drift_04` は同じ S3 のバイト列を2つの定義で読む。どちらを選んでも片側が壊れる。

| 定義 | 2019年の `age_cls_0_4` | 2020年の `age_cls_0_4` |
| --- | --- | --- |
| 128列 | 26,889(正しい) | 31,355(実は5〜9歳) |
| 127列 | 8,540(実は年齢不詳) | 25,345(正しい) |

月報のほうは位置が動かないので、世代2を足しても既存16年の集計値は 1 つも変わらない
(gen1 と gen2 の結果を突き合わせて差分 0 を確認済み)。旧名称
`kengai_tennyu_danjokei` が真の県外計の 1.74〜1.85 倍を返す性質も、足した年で
変わらず続く(`drift_05`)。`drift_06` は合計 = 県内 + 県外 を年ごとに検算して、
21 年すべて `mismatched = 0` になる(位置が動いていないことの証明)。

| 名前 | 見せること |
| --- | --- |
| `drift_01_loaded_blocks` | いまどの世代が載っているか。block ごとの行数 |
| `drift_02_age_unknown_series` | `age_unknown` の推移。世代2で 3 倍に跳ねる |
| `drift_03_shift_fingerprint` | 最終列が全 NULL になる(列削除の指紋) |
| `drift_04_two_definitions` | 128列定義と127列定義を同じ行で比べる |
| `drift_05_jinkousetai_label_drift` | 月報は名前だけずれて値は動かない |
| `drift_06_jinkousetai_positions` | 月報の位置が動いていないことの検算 |

AWS に上げる前の期待値は `./scripts/verify_drift.py` が出す。Athena の読み方
(1行目を捨てる / 位置で突き合わせる / 足りない定義列は NULL / `***` は NULL)を
手元で再現してあるので、クエリ結果が合わない場合は Terraform 側を疑える。
`--check` を付けると期待どおりでなければ非ゼロで落ちる(`make check` に入っている)。

### ズレる前とズレた後をその場で見る

世代2が載っていれば、同じテーブルの中にズレる前のブロック(1980〜2015)とズレた後の
ブロック(2020)が同居しているので、apply を往復させずに確認できる。SQL は
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

年齢各歳の CSV は `./scripts/fetch_nenreikakusai.sh` で取り直す。全 9 ブロックを
取って、128 列が 8 本・127 列が 1 本・食い違いの開始位置が 107 であることまで検査する。

## 何にお金がかかるか

データ総量は 4.5MB なのでどれも小さい。費目は S3 ストレージ、Athena のスキャン量
(最小 10MB 課金)、リクエストだけ。S3 Tables を作らないので、オブジェクト監視や
コンパクション処理の継続課金は発生しない。

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

### 数値列を bigint にしてある

型で守れそうに見えて守れない、という想定を実機で確かめるため。ずれて入ってくる値も
同じく数値なので型エラーにならない見込み。**未検証**なので
`docs/talk-script.md` の【要実測】として残してある。

### Iceberg 側は Terraform で作らない

S3 Tables は段階的に足す方針で `later/` に退避してある。スキーマ進化はデータ側の操作で、
Terraform で書くと逆に不自然になるため、戻すときもテーブルの作成までを Terraform が持ち、
データの追記は別の手段に任せる。以前はローカルの PyIceberg カタログで代替していたが、
計測を AWS 上に寄せたので 2026-10-04 に `notebooks/` ごと外した。

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
| CSV 読み | `s3:GetObject` `s3:ListBucket` | `<PREFIX>-raw-<ACCOUNT>` とその配下 |
| 結果書き | `s3:GetObject` `PutObject` `AbortMultipartUpload` `ListBucket` `ListBucketMultipartUploads` `ListMultipartUploadParts` | `<PREFIX>-athena-results-<ACCOUNT>` とその配下 |

apply 側には別途 S3 バケット作成・Glue データベース/テーブル作成・Athena
ワークグループ作成の権限が要る。S3 Tables を戻す場合に必要な `s3tables:*` は
[`later/README.md`](later/README.md) に置いてある。

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

### 世代切り替え用の変数をタグに埋めない

`Generation = tostring(var.drift_generation)` をオブジェクトのタグに置いていたら、
世代を切り替えるたびに既存オブジェクト全部がタグ更新で `change` に入り、
`Plan: 6 to add, 24 to change` になった。「ファイルを足しただけ」という検証の主張が
plan 上で見えなくなるので外した。いま何が載っているかは `drift_01` がデータ側から答える。

## 状態ファイル

ローカルの `terraform.tfstate` のまま(`.gitignore` 済み)。検証用に作って消すだけなので
リモートバックエンドは置いていない。
