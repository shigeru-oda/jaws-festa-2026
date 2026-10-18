# CSV置くだけ構成は壊れずに間違う ― 秋田のオープンデータで検証するS3 Tables

JAWS FESTA 2026 in AKITA(2026-11-07)登壇
クラウドセントリック トラック 13:40〜13:55(15分 / Lv300)
の検証リポジトリ。
[タイムテーブル](https://jawsfesta2026.jaws-ug.jp/timetable/4268f6be-274a-45f1-b5e3-ec5b56c0a0f7)

登壇ではライブデモを行わない。ここで得た数値と図をスライドに載せる。
計測は AWS 上の Athena と S3 Tables で行う(`terraform apply` → SageMaker のノートブック / Athena で SQL を実行)。
手元のスクリプトは標準ライブラリだけで動く。

## 分かったこと

題材は秋田県の「年齢別人口流動調査(県・市町村の年齢各歳、男女別人口)」。1980〜2025 年を
5 年ごとの CSV 9 本で配っていて、**2020 年版だけ `年齢不詳` の列が消えて 128 列 → 127 列** になっている。

**S3 に CSV を置いて Athena で読むと、エラーを出さずに間違った数字を返す。** CSV は列を位置で読むので、
古い 128 列の定義で 2020 年版を読むと位置 107 以降の 21 列が1つずれる。`age_unknown`(年齢不詳)は
8,540 → 25,345 と3倍に跳ね(中身は 0〜4歳)、最終列 `age_cls_95_99` は全部 NULL になる。
定義を 127 列に直すと今度は古い 8 本が逆向きにずれ、しかも NULL が出ないので痕跡が消える。

同じデータを S3 Tables(Iceberg)に見出しで読んでから入れると、2020 年も正しい列に正しい値が入る
(silver の 6,900 行が bronze と一致)。Iceberg は列を名前ではなく field ID で追うので、
列の削除・追加・順序変更・`RENAME` のどれでも既存の値は崩れない(Athena + S3 Tables で実測)。

一方で**速度は効かない**。同じ集計を Athena で 5 回ずつ流すと中央値は CSV 552 ms / S3 Tables 1,448 ms で、
この規模では CSV 直読みのほうが速い。コンパクションのジョブは成功扱いで走るが、まとめる対象が無い。

判断の軸はデータ量ではなく**列が変わるかどうか**だった。

## 動かす

```sh
# 年齢各歳 CSV の列構成と、列ずれの期待値を検査する(AWS 認証情報は不要)
./scripts/fetch_nenreikakusai.sh --check
./scripts/verify_drift.py --check

# Terraform の整形チェックと検証(AWS 認証情報は不要)
(cd terraform && terraform fmt -check -recursive && terraform validate)
```

この2本は CKAN から年齢各歳 CSV を取り直して列構成(2020 年版だけ 127 列)を確かめ、
Athena の位置読みを手元で再現した期待値と突き合わせる。標準ライブラリだけで動くので `uv sync` は要らない。

計測そのものは AWS 上で行う。`terraform apply` したあと、`scripts/sql/*.sql` を
`./scripts/run_athena_queries.py --profile <名前> --sql <ファイル>` で流すと結果が `out/` に落ちる。

## 構成

| パス | 内容 |
| --- | --- |
| `slides/main.md` | 登壇スライド(発表者ノートに話す原稿)。[README](slides/README.md) |
| `terraform/` | AWS 上に素の構成(S3 + Glue + Athena)と silver の S3 Tables を作る。[README](terraform/README.md) |
| `notebooks/landing_to_bronze.ipynb` / `bronze_to_silver.ipynb` | 年齢各歳: landing → bronze(Glue / CSV)→ silver(S3 Tables)。SageMaker で実行 |
| `scripts/run_athena_queries.py` | Athena の保存クエリを順に実行して `out/athena_*.json` に落とす |
| `scripts/verify_drift.py` | Athena の読み方(位置読み・NULL 詰め)を手元で再現して期待値を出す |
| `scripts/fetch_nenreikakusai.sh` | CKAN から年齢各歳 CSV を取り直して列構成を検査する(取得だけなら `data/fetch_nenreikakusai.sh`) |
| `scripts/fetch_akita_opendata.py` | 秋田県 CKAN の CSV 形式リソースを全部取得して台帳(`manifest.json`)を作る |
| `scripts/upload_opendata_landing.sh` | 取得した CSV を landing(`akita/landing/opendata/`)へ上げる |
| `notebooks/opendata_landing_to_bronze.ipynb` | landing → bronze。文字コード(CP932 等)・改行だけ UTF-8 / LF にそろえる |
| `notebooks/opendata_bronze_report.ipynb` | bronze を直接読み、機械判読性12項目の評価と図を自己完結 HTML 1枚に出す |
| `notebooks/opendata_akita_story.ipynb` | bronze を直接読み、一般の方向けに秋田の人口・移動・学校・クマ・発電・落とし物・地震の想定震度などを図にした HTML 1枚を出す |
| `scripts/verify_s3tables.py` | Iceberg 側の挙動(スキーマ変更・time travel・DML)と CSV との速度を Athena + S3 Tables で実測 |
| `scripts/measure_duckdb_matrix.py` | スキーマ変更ごとに形式・読み方で何が起きるかを DuckDB で実測(`uv run --with duckdb --no-project` で動かす) |
| `out/*.json` | 実測値の一次情報。スライドや README の数字はここが根拠。取り直せないものがあるのでコミット済みのものが正本 |
| `data/akita_nenreikakusai/` | 年齢各歳 CSV 9本(`data/fetch_nenreikakusai.sh` で取得。追跡しない) |
| `data/akita_opendata/` | 秋田県 CKAN の CSV 全部と台帳(`scripts/fetch_akita_opendata.py` で取得。追跡しない) |

## 秋田県オープンデータ全体の評価レポート

CSV 形式で公開されている全データセット(114件・CSV 559本、50MB 超の地震被害想定と中身が XLSX のものは除外)を
landing → bronze → HTML の順に流す。bronze は Athena を通さずノートブックが直接読む。

```sh
./scripts/fetch_akita_opendata.py              # data/akita_opendata/ に取得(約4分・26MB。50MB 超は飛ばす)
./scripts/fetch_akita_opendata.py --max-mb 0   # 地震被害想定(250m メッシュ、27本・3.4GB)も含めて取得する
./scripts/upload_opendata_landing.sh           # landing へ(AWS 認証が要る)

# 3本のノートブックを AWS に触らず手元で実行 -> work/opendata/{opendata_report,akita_report}/index.html
rm -rf work/opendata && mkdir -p work/opendata/bucket/akita/landing
cp -Rc data/akita_opendata work/opendata/bucket/akita/landing/opendata   # APFS なら複製せず参照だけ作る
cp notebooks/opendata_{landing_to_bronze,bronze_report,akita_story}.ipynb work/opendata/
cd work/opendata && OPENDATA_LOCAL_ROOT=bucket DRY_RUN=0 uv run --no-project \
  --with jupyter==1.1.1 --with nbconvert==7.16.6 jupyter nbconvert --to notebook --execute --inplace \
  opendata_landing_to_bronze.ipynb opendata_bronze_report.ipynb opendata_akita_story.ipynb
```

地震被害想定は、`--max-mb 0` で取ったときだけ bronze に入り、`opendata_akita_story.ipynb` が
27 通りの想定の最大震度を地図にする(無ければその話題を飛ばす)。機械判読性の評価(`opendata_bronze_report.ipynb`)は
1本 50MB 超を対象外にしているので、どちらで取っても数字は変わらない。

SageMaker では `opendata_landing_to_bronze.ipynb` → `opendata_bronze_report.ipynb` の順に実行する
(どちらも `DRY_RUN = True` が既定)。HTML は `akita/reports/opendata/index.html` に書く。
公開用バケットへのコピーはノートブックの外で行う。HTML は外部を読み込まず(JavaScript なし・CSP 付き)、
バケット名・アカウント ID が入っていないことを書き出す前に検査している。

## 実測値の一次情報

| ファイル | 主な内容 | 取り直し |
| --- | --- | --- |
| `out/s3tables_verification.json` | Athena + S3 Tables での Iceberg の挙動と、CSV との速度(2026-10-13) | `scripts/verify_s3tables.py` |
| `out/duckdb_schema_matrix.json` | スキーマ変更 × 形式・読み方の DuckDB 実測 | `scripts/measure_duckdb_matrix.py` |
| `out/athena_drift_gen1.json` / `gen2.json` | Athena 実機での参照先ドリフト(世代1 / 世代2。保存クエリ削除前の記録) | 取り直し不可 |
| `out/drift_verification.json` | 同じ検証の手元での期待値 | `scripts/verify_drift.py` |
| `out/athena_nen_{boundary,truth,fingerprint}_gen2.json` | ずれた列に入っている値の特定(`scripts/sql/*.sql` の結果) | `scripts/run_athena_queries.py --sql` |

`athena_drift_gen1.json` / `gen2.json` は保存クエリを消したので取り直せない。コミット済みのものが唯一の正本。
スライドの数字との突き合わせは自動化していない(2026-10-13 に原稿の検査スクリプトを外した)。

題材を年齢各歳に変える前(月報人口・人口移動理由・39県の比較)の実測と図は 2026-10-18 に外した。
必要なら `git show 4b8fdc9:out/<名前>` で取り出せる。

## 確かめたこと / まだ確かめていないこと

確かめたこと(すべて AWS 上の実機)。

- 2026-10-04: CSV + Athena で参照先が物理的にずれること(`age_unknown` 8,540 → 25,345、最終列が全 NULL)。
  `out/athena_drift_gen1.json` / `gen2.json`
- 2026-10-11: silver(S3 Tables)3 本に bronze と同じ 6,900 行が入り、正しいテーブルでは 2020 年も値がずれないこと
- 2026-10-13: S3 Tables のメンテナンスジョブ(コンパクション・スナップショット管理・未参照ファイルの削除)が
  3 テーブルとも成功していること。設定は Terraform で指定しておらず既定値
  (コンパクション目標 512MB / スナップショット保持 120 時間・最小 1 個 / 未参照 3 日・非現行 10 日)
- 2026-10-13: Iceberg 側のスキーマ変更・書き込み時の型検査・time travel・`UPDATE` / `DELETE` / `MERGE INTO`、
  CSV との速度。`out/s3tables_verification.json`
- 2026-10-13: 費用。Cost Explorer で 10/1〜10/13 の S3 Tables(東京)は約 0.008 USD。
  内訳は監視 0.0049 / ストレージ 0.0016 / リクエスト 0.0018 で、コンパクションの請求は無かった

まだ確かめていないこと。

- 同時書き込み時のアトミック性(失敗した書き込みが何も残さないことまでは確認した)
- 時刻を指定する time travel(`FOR TIMESTAMP AS OF`)。snapshot ID での巻き戻しは確認した
- データが増えて小さいファイルが溜まったときのコンパクションの効果と費用

素の構成と S3 Tables の手順は [`terraform/README.md`](terraform/README.md)。

## 出典

秋田県オープンデータポータルサイト(<https://opendata.pref.akita.lg.jp/>)を加工して作成。
ライセンス: CC BY 4.0(<https://creativecommons.org/licenses/by/4.0/deed.ja>)

JAWS-UG 支部一覧は <https://jaws-ug.jp/act/> より取得。

## 後述 — 未完了の部分と経緯

### macOS の保護フォルダ

このリポジトリは `~/Documents/github/` にあるが、`~/Documents` は macOS の保護フォルダ
(Documents / Desktop / Downloads)で、KiroCrew の gateway が launchd の常駐サービスとして
古い認可のまま生き続けると全体が `Operation not permitted` になる。
作業が止まったら `launchctl list | grep gateway` で起動時刻を確認する。
保護フォルダの外に置けば構造的に起きない。
