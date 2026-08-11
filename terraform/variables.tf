variable "region" {
  description = "リソースを作るリージョン。S3 Tables は ap-northeast-1 で利用可能(2026-08 時点で確認済み)。"
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
