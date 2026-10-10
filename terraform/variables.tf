variable "region" {
  description = "リソースを作るリージョン。"
  type        = string
  default     = "ap-northeast-1"
}

variable "profile" {
  description = "使う AWS CLI プロファイル。"
  type        = string
  default     = "default"
}

variable "name_prefix" {
  description = "リソース名の接頭辞。S3 バケット名にも使うので小文字・数字・ハイフンのみ。"
  type        = string
  default     = "jaws-festa-2026"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix は小文字・数字・ハイフンのみで、3〜32文字にしてください。"
  }
}

variable "athena_bytes_scanned_cutoff" {
  description = "1クエリでスキャンできる上限バイト数。事故で高額課金しないための保険。既定 1GiB。"
  type        = number
  default     = 1073741824
}

variable "results_expiration_days" {
  description = "Athena のクエリ結果を S3 から消すまでの日数。"
  type        = number
  default     = 7
}

variable "force_destroy" {
  description = <<-EOT
    true にすると terraform destroy でテーブル・名前空間・S3 オブジェクトごと消す。
    検証用なので既定 true。**本番では絶対に true にしない**。
  EOT
  type        = bool
  default     = true
}

variable "drift_generation" {
  description = <<-EOT
    athena_drift.tf が S3 に置くデータの世代。
    「データを追加していく中で参照先が変わるか」を測るための切り替えスイッチ。

      1 = 列が減る前だけ 年齢各歳 1980〜2015ブロック(8本・128列) / 月報 2008〜2023(16本・旧名称)
      2 = 追加後       年齢各歳 +2020ブロック(127列)          / 月報 +2006,2007,2024〜2026(新名称)

    世代1で apply して名前付きクエリを流し、結果を控えてから世代2で apply し直し、
    同じクエリを同じ順で流す。テーブル定義は一度も触らない。
    手元での期待値は ./scripts/verify_drift.py が出す。
  EOT
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2], var.drift_generation)
    error_message = "drift_generation は 1 か 2 にしてください。"
  }
}
