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
  EOT
  type        = bool
  default     = true
}
