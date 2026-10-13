# CSV置くだけ構成は壊れずに間違う ― 秋田のオープンデータで検証するS3 Tables

JAWS FESTA 2026 in AKITA(2026-11-07)登壇
クラウドセントリック トラック 13:40〜13:55(15分 / Lv300)
の検証リポジトリ。
[タイムテーブル](https://jawsfesta2026.jaws-ug.jp/timetable/4268f6be-274a-45f1-b5e3-ec5b56c0a0f7)

登壇ではライブデモを行わない。ここで得た数値と図をスライドに載せる。
計測は AWS 上の Athena で行う(`terraform apply` → Athena で SQL を実行)。
手元のスクリプトは標準ライブラリだけで動く。

## 分かったこと

**年に一度スキーマが変わるデータを、S3 に CSV を置いて Athena で読むと、エラーを出さずに
間違った数字を返す。** 秋田県の人口移動理由実態調査は 2019 年に理由の分類が 11 項目から
8 項目へ再編されており(統合・分割・削除が同時)、旧版の列定義で新版を読むと
**7 列が別の項目の値を返し、3 列が NULL になる**。

しかも **「総数 == 理由の合計」の検算は 1,521 行すべて通る**。数字は全部そこにあって、
ラベルだけが入れ替わっているためで、素朴なデータ品質チェックをすり抜ける。

Iceberg(S3 Tables)は列を位置ではなく field ID で同定するので、同じ 2 ファイルを入れると
**19 列 → 28 列**になり値は混ざらない。一方で**速度は効かない**。この規模では
CSV 直読みのほうが速く、コンパクションの出番もない。

判断の軸はデータ量ではなく**列が変わるかどうか**だった。詳細は
[`docs/comparison.md`](docs/comparison.md)。

## 動かす

```sh
make check      # 登壇原稿の数字が out/*.json と一致しているか検査する(AWS 認証情報は不要)
make tf-check   # Terraform の整形チェックと検証(AWS 認証情報は不要)
make help       # 他のターゲット
```

`make check` が通れば、`docs/talk-script.md` に書いた数字は `out/*.json` の実測値と
一致している。数字がずれたらここで落ちる。標準ライブラリだけで動くので `uv sync` は要らない。

計測そのものは AWS 上で行う。`terraform apply` したあと、`scripts/sql/*.sql` を
`./scripts/run_athena_queries.py --profile <名前> --sql <ファイル>` で流すと結果が `out/` に落ちる。

## 構成

| パス | 内容 |
| --- | --- |
| `docs/talk-script.md` | 15分の登壇スクリプト(構成・話す原稿・セルフチェック) |
| `docs/comparison.md` | 比較検証の詳細(表・図・判断軸・限界) |
| `docs/akita-opendata.md` | 同梱データの台帳(出典・ライセンス・ファイル一覧・年をまたいだ形の変化) |
| `terraform/` | AWS 上に素の構成(S3 + Glue + Athena)を作る。[README](terraform/README.md) |
| `terraform/later/` | S3 Tables の定義。段階的に足すため読み込み対象から外してある |
| `scripts/run_athena_queries.py` | Athena の保存クエリを順に実行して `out/athena_*.json` に落とす |
| `scripts/verify_drift.py` | Athena の読み方(位置読み・NULL 詰め)を手元で再現して期待値を出す |
| `scripts/fetch_nenreikakusai.sh` | CKAN から年齢各歳 CSV を取り直して列構成を検査する(取得だけなら `data/fetch_nenreikakusai.sh`) |
| `scripts/fetch_akita_opendata.py` | 秋田県 CKAN の CSV 形式リソースを全部取得して台帳(`manifest.json`)を作る |
| `scripts/upload_opendata_landing.sh` | 取得した CSV を landing(`akita/landing/opendata/`)へ上げる |
| `notebooks/opendata_landing_to_bronze.ipynb` | landing → bronze。文字コード(CP932 等)・改行だけ UTF-8 / LF にそろえる |
| `notebooks/opendata_bronze_report.ipynb` | bronze を直接読み、機械判読性12項目の評価と図を自己完結 HTML 1枚に出す |
| `scripts/check_talk_numbers.py` | 原稿の数字が実測値と一致しているかの検査 |
| `scripts/retime_talk_script.py` | 原稿の尺(見出しの時刻・尺表)を文字数から再生成 |
| `scripts/measure_duckdb_matrix.py` | スキーマ変更ごとに形式・読み方で何が起きるかを DuckDB で実測(`uv run --with duckdb --no-project` で動かす) |
| `out/*.json` | 実測値の一次情報。原稿や README の数字はここが根拠。再生成元を持たないのでコミット済みのものが正本 |
| `out/*.png` | スライド用の図。同じく正本(`make clean` では消さない) |
| `data/akita/` | 秋田県ポータルの CSV 19本 + XLSX 1本 |
| `data/akita_idouriyuu/` | 人口移動理由実態調査 CSV 6本 |
| `data/prefectures/` | 他県の市町村別人口 CSV。**ライセンスが県ごとに異なるため追跡しない**(下記) |
| `data/jawsug/` | JAWS-UG 支部一覧(43支部 / 39都道府県) |

## 秋田県オープンデータ全体の評価レポート

CSV 形式で公開されている全データセット(114件・CSV 559本、50MB 超の地震被害想定と中身が XLSX のものは除外)を
landing → bronze → HTML の順に流す。bronze は Athena を通さずノートブックが直接読む。

```sh
make opendata-fetch     # data/akita_opendata/ に取得(約4分・26MB)
make opendata-upload    # landing へ(AWS 認証が要る)
make opendata-local     # 2本のノートブックを AWS に触らず手元で実行 -> work/opendata/opendata_report/index.html
```

SageMaker では `opendata_landing_to_bronze.ipynb` → `opendata_bronze_report.ipynb` の順に実行する
(どちらも `DRY_RUN = True` が既定)。HTML は `akita/reports/opendata/index.html` に書く。
公開用バケットへのコピーはノートブックの外で行う。HTML は外部を読み込まず(JavaScript なし・CSP 付き)、
バケット名・アカウント ID が入っていないことを書き出す前に検査している。

## 実測値の一次情報

| ファイル | 主な内容 | 取り直し |
| --- | --- | --- |
| `out/athena_drift_gen1.json` / `gen2.json` | Athena 実機での参照先ドリフト(世代1 / 世代2。保存クエリ削除前の記録) | 取り直し不可 |
| `out/drift_verification.json` | 同じ検証の手元での期待値 | `scripts/verify_drift.py` |
| `out/rename_blindspot.json` | リネームの内訳 / 意味が不変であることの検算 / 過大率 | 不可(コミット済みが正本) |
| `out/athena_vs_s3tables.json` | 誤読の内訳 / 検算の通過率 / Iceberg の列数・snapshot / 規模と速度 | 不可 |
| `out/akita_now.json` / `summary.json` | 秋田の人口推移・高齢化率・移動理由の内訳 | 不可 |
| `out/prefecture_comparison.json` | 39県調査の集計 + 19ファイルのヘッダ全文 | 不可(元データを追跡していない) |

「取り直し」が不可のものは、2026-10-04 に `notebooks/` を外した時点で再生成元が無くなった。
コミット済みのファイルが唯一の正本で、`scripts/check_talk_numbers.py` はこれを読んで
原稿の必須44件を検査する。生成コードは git 履歴に残っているので、必要になったら
`git show 64c9f75:notebooks/<名前>.py` で取り出せる。

図は `out/rename_overstate.png`(リネームによる過大)、`out/athena_misread.png`(誤読。デッキ243行目で使用)、`out/idouriyuu_reasons.png`(理由別推移)、
`out/population_trend.png` / `population_change.png` / `aging_ratio.png`(秋田の人口)、
`out/pref_columns.png` / `pref_platforms.png`(全国比較)。いずれも同じく正本。

## 確かめたこと / まだ確かめていないこと

Athena 実機は 2026-10-04 に検証済み。`terraform apply` して保存クエリ12本を実行し、
参照先が物理的にずれること(`age_unknown` が 8,540 → 25,345、最終列が全 NULL)を
実データで確認した。結果は `out/athena_drift_gen1.json` / `gen2.json`。

まだ確かめていないのは S3 Tables 側。

- S3 Tables 本体(テーブルバケット・自動コンパクション・オブジェクト監視課金)。
  一度 apply して空テーブルの作成まで確認したが、データを入れた比較はしていない
- 両構成のコスト。試算も実測もまだ無い

S3 Tables の Terraform は段階的に足すため [`terraform/later/`](terraform/later/README.md)
に退避してある(読み込み対象外)。戻す手順はそちらの README。素の構成の手順は
[`terraform/README.md`](terraform/README.md)。

## 出典

秋田県オープンデータポータルサイト(<https://opendata.pref.akita.lg.jp/>)を加工して作成。
ライセンス: CC BY 4.0(<https://creativecommons.org/licenses/by/4.0/deed.ja>)

他都道府県のデータは各県のポータルから取得したが、**ライセンスが県ごとに異なる**ため
(CC BY 4.0 / CC BY 2.1 日本 / Public Data License 1.0 / 政府標準利用規約系)、
再配布の可否を県ごとに確認できていない。**このリポジトリでは追跡していない**
(`data/prefectures/` は `.gitignore`)。

集計結果は `out/prefecture_comparison.json` にコミットしてあるので、全国比較の数値と
19ファイルのヘッダは clone しただけで参照できる。集計していたノートブックは
2026-10-04 に外したので、取り直すには各県のポータルからデータをダウンロードした上で
`git show 64c9f75:notebooks/prefecture_schemas.py` を取り出す必要がある。

JAWS-UG 支部一覧は <https://jaws-ug.jp/act/> より取得。

## 後述 — 未完了の部分と経緯

### 39都道府県の調査は 36 県で確定、3 県が未確認

島根・岡山・広島が未確認。ただし「市町村別人口を CSV で出しているのは 16 県」という数字は
**確認済みの県だけで数えた下限**なので、残る 3 県で CSV が見つかっても増える方向にしか動かない。

- 岡山県: CSV としてダウンロードしたファイルの**実体が XLSX** だった
  (`data/prefectures/okayama_population.xlsx`)
- 島根県 / 広島県: 人口は Excel のみという所見
- 高知県: 公式 CSV が無く XLS/PDF のみ。XLS から変換したものは
  `kochi_population.derived.csv` として集計対象から外している
- 大阪府: `portal.datapf.pref.osaka.jp` へ接続できなかった。CKAN メタ上は CSV / CC BY 4.0 だが
  BODIK ミラー側には GeoJSON しかない

### 県名の対応表の漏れで集計が汚れた

`prefecture_schemas.py` の `PREF_OF_FILE`(ファイル名 → 県名)に徳島・香川が無く、
`tokushima` というローマ字のまま JSON に載っていた。ローマ字フォールバックを廃止し、
未登録ファイルがあれば `assert` で落ちるようにした。同時に集計が
19ファイル / Shift_JIS 11 に更新され、原稿の 17ファイル / 9 という記述が古くなっていたことが
`make check` で判明した。**この検査を先に作っておいたのが効いた。**

### macOS の保護フォルダ

このリポジトリは `~/Documents/github/` にあるが、`~/Documents` は macOS の保護フォルダ
(Documents / Desktop / Downloads)で、KiroCrew の gateway が launchd の常駐サービスとして
古い認可のまま生き続けると全体が `Operation not permitted` になる。
作業が止まったら `launchctl list | grep gateway` で起動時刻を確認する。
保護フォルダの外に置けば構造的に起きない。
