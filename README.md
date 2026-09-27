# CSV置くだけ構成は壊れずに間違う ― 秋田のオープンデータで検証するS3 Tables

JAWS FESTA 2026 in AKITA(2026-11-07)登壇
クラウドセントリック トラック 13:40〜13:55(15分 / Lv300)
の検証リポジトリ。
[タイムテーブル](https://jawsfesta2026.jaws-ug.jp/timetable/4268f6be-274a-45f1-b5e3-ec5b56c0a0f7)

登壇ではライブデモを行わない。ここで得た数値と図をスライドに載せる。
ノートブックは marimo だが**保存形式は普通の `.py`** なので、差分が読めてそのまま実行できる。

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
uv sync
make verify     # ノートブックを通してから、登壇原稿の数字と突き合わせる
make tf-check   # Terraform の整形チェックと検証(AWS 認証情報は不要)
make edit       # marimo で対話的に触る (NB=akita_iceberg などで指定)
make help       # 他のターゲット
```

`make verify` が通れば、`docs/talk-script.md` に書いた数字は `out/*.json` の実測値と
一致している。数字がずれたらここで落ちる。

## 構成

| パス | 内容 |
| --- | --- |
| `notebooks/rename_blindspot.py` | **本題**: 列名のリネームに気づけないことの再現 |
| `notebooks/athena_vs_s3tables.py` | 列削除で値がずれることの再現(壊れ方その2) |
| `notebooks/akita_iceberg.py` | 秋田県のデータでスキーマ進化・タイムトラベルを確認 |
| `notebooks/prefecture_schemas.py` | JAWS-UG 支部がある 39 都道府県のスキーマ横断比較 |
| `docs/talk-script.md` | 15分の登壇スクリプト(構成・話す原稿・セルフチェック) |
| `docs/comparison.md` | 比較検証の詳細(表・図・判断軸・限界) |
| `terraform/` | AWS 上に2つの構成を作る(素の S3+Glue+Athena / S3 Tables)。[README](terraform/README.md) |
| `scripts/check_talk_numbers.py` | 原稿の数字が実測値と一致しているかの検査 |
| `scripts/retime_talk_script.py` | 原稿の尺(見出しの時刻・尺表)を文字数から再生成 |
| `out/*.json` | **実測値の一次情報**。原稿や README の数字はここが根拠 |
| `out/*.png` | スライド用の図 |
| `data/akita/` | 秋田県ポータルの CSV 19本 + XLSX 1本 |
| `data/akita_idouriyuu/` | 人口移動理由実態調査 CSV 6本 |
| `data/prefectures/` | 他県の市町村別人口 CSV。**ライセンスが県ごとに異なるため追跡しない**(下記) |
| `data/jawsug/` | JAWS-UG 支部一覧(43支部 / 39都道府県) |

## 実測値の一次情報

| ファイル | 主な内容 |
| --- | --- |
| `out/rename_blindspot.json` | リネームの内訳 / 意味が不変であることの検算 / 過大率 |
| `out/athena_vs_s3tables.json` | 誤読の内訳 / 検算の通過率 / Iceberg の列数・snapshot / 規模と速度 |
| `out/summary.json` | 秋田の人口推移・高齢化率・スキーマ進化の差分 |
| `out/prefecture_comparison.json` | 39県調査の集計 + 19ファイルのヘッダ全文 |

図は `out/rename_overstate.png`(リネームによる過大)、`out/athena_misread.png`(誤読)、`out/idouriyuu_reasons.png`(理由別推移)、
`out/population_trend.png` / `population_change.png` / `aging_ratio.png`(秋田の人口)、
`out/pref_columns.png` / `pref_platforms.png`(全国比較)。

## まだ確かめていないこと

- **S3 Tables 本体**(テーブルバケット・自動コンパクション・オブジェクト監視課金・IAM 認可)。
  ローカルは PyIceberg + SQLite カタログで代替している
- **Athena 実機**。列の位置読みは DuckDB で模擬している(`auto_detect=false` が要る)
- **両構成のコスト**。試算も実測もまだ無い

`terraform/` に**両構成を作る Terraform は書いてある**(`terraform validate` は通る)。
`apply` していないので、上記はまだ実測できていない。手順は
[`terraform/README.md`](terraform/README.md)。

S3 Tables に向けるときは、ノートブックのカタログ生成をこう差し替える。

```python
from pyiceberg.catalog import load_catalog

catalog = load_catalog("s3tables", **{
    "type": "rest",
    "uri": "https://glue.<region>.amazonaws.com/iceberg",
    "rest.sigv4-enabled": "true",
})
```

権限は IAM と(Glue エンドポイント経由なら)Lake Formation の grant が必要。
2026-03 の「S3 Tables / Iceberg マテビューの IAM ベース認可」対応で、
ストレージ・カタログ・クエリの権限を単一の IAM ポリシーに寄せられる。

## 出典

秋田県オープンデータポータルサイト(<https://opendata.pref.akita.lg.jp/>)を加工して作成。
ライセンス: CC BY 4.0(<https://creativecommons.org/licenses/by/4.0/deed.ja>)

他都道府県のデータは各県のポータルから取得したが、**ライセンスが県ごとに異なる**ため
(CC BY 4.0 / CC BY 2.1 日本 / Public Data License 1.0 / 政府標準利用規約系)、
再配布の可否を県ごとに確認できていない。**このリポジトリでは追跡していない**
(`data/prefectures/` は `.gitignore`)。

集計結果は `out/prefecture_comparison.json` にコミットしてあるので、全国比較の数値と
19ファイルのヘッダは clone しただけで参照できる。データを取り直して
`notebooks/prefecture_schemas.py` を再実行したい場合は、各県のポータルから
自分でダウンロードする(`make verify` はデータが無ければ SKIP と表示する)。

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
