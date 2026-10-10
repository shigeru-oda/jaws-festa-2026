# ─────────────────────────────────────────────────────────────────────────────
# Glue: カタログ DB と「素の構成(汎用バケット + CSV)」のテーブル定義。
#
# https://docs.aws.amazon.com/athena/latest/ug/handling-schema-updates-chapter.html
# ─────────────────────────────────────────────────────────────────────────────

locals {
  glue_db    = replace("${var.name_prefix}_akita", "-", "_")
  csv_prefix = "idouriyuu"
  data_dir   = "${path.module}/../data/akita_idouriyuu"
  csv_objects = {
    "01_kaitousya_2013-2018.csv" = "2013-2018 版 19列 11理由"
    "03_kaitousya_2019-2025.csv" = "2019-2025 版 16列 8理由"
  }
}

resource "aws_glue_catalog_database" "akita" {
  name        = local.glue_db
  description = "秋田県オープンデータ(CC BY 4.0)。素の S3+Athena 構成との比較用。"
}

resource "aws_glue_catalog_table" "idouriyuu_csv" {
  name          = "idouriyuu_csv"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "テーブル定義は 2013-2018 版の19列。2019-2025 版(16列)も同じ定義で読まれる。"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.raw.id}/${local.csv_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"

      parameters = {
        "field.delim"          = ","
        "serialization.format" = ","
      }
    }

    # 識別列(7列)
    columns {
      name = "nengetsubi_code"
      type = "string"
    }
    columns {
      name = "nengetsubi"
      type = "string"
    }
    columns {
      name = "idou_kubun_code"
      type = "string"
    }
    columns {
      name = "idou_kubun"
      type = "string"
    }
    columns {
      name = "danjo_code"
      type = "string"
    }
    columns {
      name = "danjo"
      type = "string"
    }
    columns {
      name = "nenrei_kaikyu"
      type = "string"
    }
    columns {
      name = "sosu"
      type = "bigint"
    }
    columns {
      name = "tenkin"
      type = "bigint"
    }
    columns {
      name = "tengyo_tenshoku"
      type = "bigint"
    }
    columns {
      name = "shushoku"
      type = "bigint"
    }
    columns {
      name = "kagyo_kokei"
      type = "bigint"
    }
    columns {
      name = "shingaku_tenko"
      type = "bigint"
    }
    columns {
      name = "sotsugyo"
      type = "bigint"
    }
    columns {
      name = "kekkon_rikon"
      type = "bigint"
    }
    columns {
      name = "oya_to_dokyo"
      type = "bigint"
    }
    columns {
      name = "ko_mago_to_dokyo"
      type = "bigint"
    }
    columns {
      name = "jutaku_jijo"
      type = "bigint"
    }
    columns {
      name = "sonota"
      type = "bigint"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 月報人口・世帯のテーブル定義。CSV・S3オブジェクトは s3.tf、クエリは
# athena.tf 参照。
#
# 2008〜2023 (16年) と 2006〜2007・2024〜2026 (5年) で見出しの流派が
# 2つに分かれているが、列数は全ファイルで36のまま変わらない。位置が動かない
# ので、Athena の CSV テーブル(列を位置で読む)はどちらの定義でもエラーを
# 出さずに全年を読む。壊れるのは SQL ではなく、列名が指している意味。
#
# https://docs.aws.amazon.com/athena/latest/ug/partition-projection.html
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # 36 列の対応表。素の構成では、この表が人間の頭の中にしか無い状態になる。
  # old = 2008〜2023 の見出し / new = 2006〜2007・2024〜2026 の見出し。
  # 10 列は共通で、26 列が食い違う。
  jks_columns = [
    { old = "nengetsubi_code", new = "nengetsubi_code", type = "string", ja_old = "年月日コード", ja_new = "年月日コード" },
    { old = "nengetsubi", new = "nengetsubi", type = "string", ja_old = "年月日", ja_new = "年月日" },
    { old = "kubun_code", new = "kubun_code", type = "string", ja_old = "区分コード", ja_new = "区分コード" },
    { old = "kubun", new = "kubun", type = "string", ja_old = "区分", ja_new = "区分" },
    { old = "jinko_danjokei", new = "jinko_sosu", type = "bigint", ja_old = "人口・男女計（人）", ja_new = "人口・総数（人）" },
    { old = "jinko_otoko", new = "jinko_otoko_kei", type = "bigint", ja_old = "人口・男（人）", ja_new = "人口・男計（人）" },
    { old = "jinko_onna", new = "jinko_onna_kei", type = "bigint", ja_old = "人口・女（人）", ja_new = "人口・女計（人）" },
    { old = "jinko_zogen_danjokei", new = "jinko_zogen_gokei", type = "bigint", ja_old = "人口増減数・男女計（人）", ja_new = "人口増減数・合計（人）" },
    { old = "jinko_zogen_otoko", new = "jinko_zogen_otoko_kei", type = "bigint", ja_old = "人口増減数・男（人）", ja_new = "人口増減数・男計（人）" },
    { old = "jinko_zogen_onna", new = "jinko_zogen_onna_kei", type = "bigint", ja_old = "人口増減数・女（人）", ja_new = "人口増減数・女計（人）" },
    { old = "shussei_danjokei", new = "shussei_gokei", type = "bigint", ja_old = "出生・男女計（人）", ja_new = "出生・合計（人）" },
    { old = "shussei_otoko", new = "shussei_otoko_kei", type = "bigint", ja_old = "出生・男（人）", ja_new = "出生・男計（人）" },
    { old = "shussei_onna", new = "shussei_onna_kei", type = "bigint", ja_old = "出生・女（人）", ja_new = "出生・女計（人）" },
    { old = "shibo_danjokei", new = "shibo_gokei", type = "bigint", ja_old = "死亡・男女計（人）", ja_new = "死亡・合計（人）" },
    { old = "shibo_otoko", new = "shibo_otoko_kei", type = "bigint", ja_old = "死亡・男（人）", ja_new = "死亡・男計（人）" },
    { old = "shibo_onna", new = "shibo_onna_kei", type = "bigint", ja_old = "死亡・女（人）", ja_new = "死亡・女計（人）" },
    { old = "shizen_zogen_danjokei", new = "shizen_zogen_gokei", type = "bigint", ja_old = "自然増減数・男女計（人）", ja_new = "自然増減数・合計（人）" },
    { old = "shizen_zogen_otoko", new = "shizen_zogen_otoko_kei", type = "bigint", ja_old = "自然増減数・男（人）", ja_new = "自然増減数・男計（人）" },
    { old = "shizen_zogen_onna", new = "shizen_zogen_onna_kei", type = "bigint", ja_old = "自然増減数・女（人）", ja_new = "自然増減数・女計（人）" },
    # ★ ここが登壇の中心。旧名称は「県外転入」だが、中身は県内＋県外の合計。
    { old = "kengai_tennyu_danjokei", new = "tennyu_gokei", type = "bigint", ja_old = "県外転入・男女計（人）", ja_new = "転入・合計（人）" },
    { old = "kengai_tennyu_otoko", new = "tennyu_otoko_kei", type = "bigint", ja_old = "県外転入・男（人）", ja_new = "転入・男計（人）" },
    { old = "kengai_tennyu_onna", new = "tennyu_onna_kei", type = "bigint", ja_old = "県外転入・女（人）", ja_new = "転入・女計（人）" },
    { old = "kennai_tennyu_danjokei", new = "tennyu_kennai_kei", type = "bigint", ja_old = "県内転入・男女計（人）", ja_new = "転入・県内計（人）" },
    # 位置24 は両方の流派で同名。つまり1つのファイルの中に
    # 「県外転入・男女計」と「転入・県外計」が併存していた。
    { old = "tennyu_kengai_kei", new = "tennyu_kengai_kei", type = "bigint", ja_old = "転入・県外計（人）", ja_new = "転入・県外計（人）" },
    { old = "kengai_tenshutsu_danjokei", new = "tenshutsu_gokei", type = "bigint", ja_old = "県外転出・男女計（人）", ja_new = "転出・合計（人）" },
    { old = "kengai_tenshutsu_otoko", new = "tenshutsu_otoko_kei", type = "bigint", ja_old = "県外転出・男（人）", ja_new = "転出・男計（人）" },
    { old = "kengai_tenshutsu_onna", new = "tenshutsu_onna_kei", type = "bigint", ja_old = "県外転出・女（人）", ja_new = "転出・女計（人）" },
    { old = "kennai_tenshutsu_danjokei", new = "tenshutsu_kennai_kei", type = "bigint", ja_old = "県内転出・男女計（人）", ja_new = "転出・県内計（人）" },
    { old = "tenshutsu_kengai_kei", new = "tenshutsu_kengai_kei", type = "bigint", ja_old = "転出・県外計（人）", ja_new = "転出・県外計（人）" },
    { old = "shakai_zogen_danjokei", new = "shakai_zogen_gokei", type = "bigint", ja_old = "社会増減数・男女計（人）", ja_new = "社会増減数・合計（人）" },
    { old = "shakai_zogen_otoko", new = "shakai_zogen_otoko_kei", type = "bigint", ja_old = "社会増減数・男（人）", ja_new = "社会増減数・男計（人）" },
    { old = "shakai_zogen_onna", new = "shakai_zogen_onna_kei", type = "bigint", ja_old = "社会増減数・女（人）", ja_new = "社会増減数・女計（人）" },
    { old = "setaisu", new = "setaisu", type = "bigint", ja_old = "世帯数（世帯）", ja_new = "世帯数（世帯）" },
    { old = "zoka_setaisu", new = "zoka_setaisu", type = "bigint", ja_old = "増加世帯数（世帯）", ja_new = "増加世帯数（世帯）" },
    { old = "gensho_setaisu", new = "gensho_setaisu", type = "bigint", ja_old = "減少世帯数（世帯）", ja_new = "減少世帯数（世帯）" },
    { old = "setai_zogen", new = "setai_zogen", type = "bigint", ja_old = "世帯増減数（世帯）", ja_new = "世帯増減数（世帯）" },
  ]

  jks_renamed_count = length([for c in local.jks_columns : c if c.old != c.new])
}

# ── Glue テーブル(1): 旧名称「男女計」系で定義 ─────────────────────────────
# 2008〜2023 の見出しをそのまま列名にしたテーブル。素の構成で誰かが 2020 年版の
# CSV を見ながら作る定義がこれになる。2024 年以降も位置で読まれるので、
# kengai_tennyu_danjokei は**県外転入ではない値**を返し続ける。
resource "aws_glue_catalog_table" "jinkousetai_csv" {
  name          = "jinkousetai_csv"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "定義は 2008-2023 版の見出し(旧名称)。全21年を同じ定義で読む。"

    # パーティション射影。year は 2006〜2026 の範囲から機械的に導くので、
    # 新しい年のファイルを置いても Glue のパーティション登録は不要。
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2006,2026"
    "projection.year.interval"  = "1"
    "storage.location.template" = "s3://${aws_s3_bucket.raw.id}/${local.jks_prefix}/year=$${year}/"
  }

  partition_keys {
    name    = "year"
    type    = "int"
    comment = "ファイル1本=1年。WHERE year = 2020 でスキャン対象を1本に絞れる。"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.raw.id}/${local.jks_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"

      parameters = {
        "field.delim"          = ","
        "serialization.format" = ","

        # 欠測は "***"。bigint 列では解釈できない値として NULL になる。
        # 明示したい場合は "serialization.null.format" = "***" を足す。
        # ここでは**素の構成がやりがちな既定のまま**を見せるので足していない。
      }
    }

    # 日本語の見出しはそのまま列名にできない(Athena は列名に英小文字・数字・
    # アンダースコアだけを許す)。ローマ字に落とす時点で、元の見出しとの
    # 対応は人間が覚えておくしかなくなる。comment に原文を残している。
    dynamic "columns" {
      for_each = local.jks_columns

      content {
        name    = columns.value.old
        type    = columns.value.type
        comment = columns.value.ja_old
      }
    }
  }
}

# ── Glue テーブル(2): 新名称「総数・合計」系で定義 ─────────────────────────
# 同じ S3 プレフィックスを、2006〜2007・2024〜2026 の見出しで読む。
# 位置は1つも動かないので、返る数値は(1)と完全に一致する。
# 変わるのは列名だけ ―― つまり「どちらの定義でも Athena は黙って通る」。
resource "aws_glue_catalog_table" "jinkousetai_csv_sosu" {
  name          = "jinkousetai_csv_sosu"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "定義は 2006-2007・2024-2026 版の見出し(新名称)。(1)と同じバイト列を読む。"

    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2006,2026"
    "projection.year.interval"  = "1"
    "storage.location.template" = "s3://${aws_s3_bucket.raw.id}/${local.jks_prefix}/year=$${year}/"
  }

  partition_keys {
    name = "year"
    type = "int"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.raw.id}/${local.jks_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"

      parameters = {
        "field.delim"          = ","
        "serialization.format" = ","
      }
    }

    dynamic "columns" {
      for_each = local.jks_columns

      content {
        name    = columns.value.new
        type    = columns.value.type
        comment = columns.value.ja_new
      }
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# drift 検証用のテーブル定義。「データを追加していく中で、参照先のデータが
# 変わってしまう」の検証(S3オブジェクトは s3.tf、クエリは athena.tf)。
#
# 題材は年齢別人口流動調査の2つの表。同じ調査なのに壊れ方が違う。
#
#   年齢各歳 (050008_toukeika_032) : 2020ブロックで列が1本消える
#       -> 参照先が物理的にずれる。列名はそのままで中身が隣の列になる。
#   月報     (050008_toukeika_031) : 2024年で26列の名前が変わる
#       -> 位置は動かない。値はそのまま。ずれるのは列名の意味だけ。
#
# 手元での期待値は ./scripts/verify_drift.py が出す(Athena の位置読みを再現してある)。
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # ── 年齢各歳の列定義 ──────────────────────────────────────────────────────
  # 物理レイアウト(1980〜2015ブロック・128列):
  #   0-5     年月日コード / 年月日 / 市町村コード / 市町村 / 男女別 / 総数
  #   6-105   0歳 〜 99歳 (各歳100列)
  #   106     100歳以上
  #   107     年齢不詳          <- 2020ブロックではこの列が消える
  #   108-127 0〜4歳 〜 95〜99歳 (5歳階級20列)
  drift_nen_head = [
    { name = "nengetsubi_code", type = "string", ja = "年月日コード" },
    { name = "nengetsubi", type = "string", ja = "年月日" },
    { name = "shichoson_code", type = "string", ja = "市町村コード" },
    { name = "shichoson", type = "string", ja = "市町村" },
    { name = "danjo", type = "string", ja = "男女別" },
    { name = "sosu", type = "bigint", ja = "総数" },
  ]
  drift_nen_ages = [
    for i in range(0, 100) : { name = "age_${i}", type = "bigint", ja = "${i}歳" }
  ]
  drift_nen_classes = [
    for i in range(0, 20) : {
      name = "age_cls_${i * 5}_${i * 5 + 4}"
      type = "bigint"
      ja   = "${i * 5}～${i * 5 + 4}歳"
    }
  ]

  # 定義(A): 2015ブロックまでを見て作った128列。位置107に年齢不詳がある。
  drift_nen_cols_128 = concat(
    local.drift_nen_head,
    local.drift_nen_ages,
    [{ name = "age_100_plus", type = "bigint", ja = "100歳以上" }],
    [{ name = "age_unknown", type = "bigint", ja = "年齢不詳(2020ブロックには存在しない)" }],
    local.drift_nen_classes,
  )

  # 定義(B): 2020ブロックを見て作り直した127列。年齢不詳を外しただけ。
  drift_nen_cols_127 = concat(
    local.drift_nen_head,
    local.drift_nen_ages,
    [{ name = "age_100_plus", type = "bigint", ja = "100歳以上" }],
    local.drift_nen_classes,
  )
}

# ── Glue テーブル(A): 年齢各歳を128列の定義で読む ───────────────────────────
# 世代1のデータだけを見て作った定義。世代2でファイルを足しても、この定義は
# 変えない。2020ブロックの行は age_unknown の欄に 0〜4歳 の値を返し、
# 最後の age_cls_95_99 が NULL になる。
#
# パーティション射影は全9ブロックを列挙してある。世代1では2020ブロックの
# ファイルが存在しないので、該当パーティションは単に0行として扱われる。
resource "aws_glue_catalog_table" "drift_nenreikakusai_128" {
  name          = "drift_nenreikakusai_128"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "定義は1980〜2015ブロックの見出し(128列)。年齢不詳が位置107にある前提。"

    "projection.enabled"        = "true"
    "projection.block.type"     = "enum"
    "projection.block.values"   = join(",", local.drift_nen_blocks_all)
    "storage.location.template" = "s3://${aws_s3_bucket.raw.id}/${local.drift_nen_prefix}/block=$${block}/"
  }

  partition_keys {
    name    = "block"
    type    = "string"
    comment = "5年ブロックの先頭年。block='2020' だけが物理127列。"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.raw.id}/${local.drift_nen_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"

      parameters = {
        "field.delim"          = ","
        "serialization.format" = ","
      }
    }

    dynamic "columns" {
      for_each = local.drift_nen_cols_128

      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.ja
      }
    }
  }
}

# ── Glue テーブル(B): 同じデータを127列の定義で読む ─────────────────────────
# 「列が消えたと気づいて定義を作り直した」側。2020ブロックは正しく読めるが、
# 今度は1980〜2015ブロックが1つ右にずれる(age_cls_0_4 に 年齢不詳 の値が入る)。
# CSV のままではどちらの定義でも全期間を正しく読めない、というのがこの対比。
resource "aws_glue_catalog_table" "drift_nenreikakusai_127" {
  name          = "drift_nenreikakusai_127"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "定義は2020ブロックの見出し(127列)。年齢不詳が無い前提。"

    "projection.enabled"        = "true"
    "projection.block.type"     = "enum"
    "projection.block.values"   = join(",", local.drift_nen_blocks_all)
    "storage.location.template" = "s3://${aws_s3_bucket.raw.id}/${local.drift_nen_prefix}/block=$${block}/"
  }

  partition_keys {
    name    = "block"
    type    = "string"
    comment = "5年ブロックの先頭年。"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.raw.id}/${local.drift_nen_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"

      parameters = {
        "field.delim"          = ","
        "serialization.format" = ","
      }
    }

    dynamic "columns" {
      for_each = local.drift_nen_cols_127

      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.ja
      }
    }
  }
}

# ── Glue テーブル(C): 月報を旧名称の定義で読む ──────────────────────────────
# 列定義は jks_columns を使い回す(旧名称側)。
# 世代2で新名称のファイルを足しても、位置が動かないので既存年の数値は1つも
# 変わらない。変わるのは「kengai_tennyu_danjokei という名前が何を指すか」だけ。
resource "aws_glue_catalog_table" "drift_jinkousetai_kyu" {
  name          = "drift_jinkousetai_kyu"
  database_name = aws_glue_catalog_database.akita.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
    EXTERNAL                 = "TRUE"
    comment                  = "定義は2008〜2023版の見出し(旧名称36列)。世代をまたいでも定義は変えない。"

    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2006,2026"
    "projection.year.interval"  = "1"
    "storage.location.template" = "s3://${aws_s3_bucket.raw.id}/${local.drift_jks_prefix}/year=$${year}/"
  }

  partition_keys {
    name    = "year"
    type    = "int"
    comment = "ファイル1本=1年。"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.raw.id}/${local.drift_jks_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"

      parameters = {
        "field.delim"          = ","
        "serialization.format" = ","
      }
    }

    dynamic "columns" {
      for_each = local.jks_columns

      content {
        name    = columns.value.old
        type    = columns.value.type
        comment = columns.value.ja_old
      }
    }
  }
}
