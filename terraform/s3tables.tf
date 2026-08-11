# ─────────────────────────────────────────────────────────────────────────────
# S3 Tables 側(マネージド Iceberg)
#
# 汎用バケットとは別種の「テーブルバケット」を作る。CSV を置くのではなく
# テーブルとして取り込み直す構成になる。
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3tables_table_bucket" "main" {
  name          = "${var.name_prefix}-tables"
  force_destroy = var.force_destroy

  encryption_configuration = {
    sse_algorithm = "AES256"
    kms_key_arn   = null # SSE-S3 なので KMS キーは使わない
  }

  # バケット単位のメンテナンス: 参照されなくなったデータファイルの削除。
  # スナップショットが期限切れになった後に残る孤児ファイルを掃除する。
  maintenance_configuration = {
    iceberg_unreferenced_file_removal = {
      status = "enabled"
      settings = {
        unreferenced_days = 3 # 参照されなくなってから削除マークを付けるまで
        non_current_days  = 1 # 削除マークから実削除まで
      }
    }
  }
}

resource "aws_s3tables_namespace" "akita" {
  namespace        = var.namespace
  table_bucket_arn = aws_s3tables_table_bucket.main.arn
}

# 人口移動理由実態調査(2013-2018 版)のスキーマ。
#
# ノートブック(PyIceberg)は同じ名前空間に別テーブルを作り、2019-2025 版を
# union_by_name で追記して 19列 -> 28列 に育てる。こちらは
# 「Terraform で宣言したスキーマ」と「テーブル単位のメンテナンス設定」を
# 見せるための固定テーブル。
resource "aws_s3tables_table" "idouriyuu" {
  name             = var.table_name
  namespace        = aws_s3tables_namespace.akita.namespace
  table_bucket_arn = aws_s3tables_namespace.akita.table_bucket_arn
  format           = "ICEBERG"

  metadata {
    iceberg {
      schema {
        # 識別列(7列)
        field {
          name     = "nengetsubi_code"
          type     = "string"
          required = true
        }
        field {
          name = "nengetsubi"
          type = "string"
        }
        field {
          name = "idou_kubun_code"
          type = "string"
        }
        field {
          name = "idou_kubun"
          type = "string"
        }
        field {
          name = "danjo_code"
          type = "string"
        }
        field {
          name = "danjo"
          type = "string"
        }
        field {
          name = "nenrei_kaikyu"
          type = "string"
        }

        # 総数 + 旧分類の 11 理由(2013-2018 版)
        field {
          name = "sosu"
          type = "long"
        }
        field {
          name = "tenkin"
          type = "long"
        }
        field {
          name = "tengyo_tenshoku"
          type = "long"
        }
        field {
          name = "shushoku"
          type = "long"
        }
        field {
          name = "kagyo_kokei"
          type = "long"
        }
        field {
          name = "shingaku_tenko"
          type = "long"
        }
        field {
          name = "sotsugyo"
          type = "long"
        }
        field {
          name = "kekkon_rikon"
          type = "long"
        }
        field {
          name = "oya_to_dokyo"
          type = "long"
        }
        field {
          name = "ko_mago_to_dokyo"
          type = "long"
        }
        field {
          name = "jutaku_jijo"
          type = "long"
        }
        field {
          name = "sonota"
          type = "long"
        }
      }
    }
  }

  # テーブル単位のメンテナンス: コンパクションとスナップショット管理。
  # 数MBでは効かないことを示すのが登壇の論点なので、既定で有効にしたうえで
  # 「対象になる小ファイルがそもそも溜まらない」ことを実測する。
  maintenance_configuration = {
    iceberg_compaction = {
      status = var.enable_compaction ? "enabled" : "disabled"
      settings = {
        target_file_size_mb = var.target_file_size_mb
      }
    }

    iceberg_snapshot_management = {
      status = "enabled"
      settings = {
        # タイムトラベルの実演に使うので、既定より長く保持する
        max_snapshot_age_hours = 168 # 7日
        min_snapshots_to_keep  = 5
      }
    }
  }
}
