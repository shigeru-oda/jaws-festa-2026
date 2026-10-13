#!/usr/bin/env bash
# data/akita_opendata/ を landing にそのまま上げる(加工しない)。
#
#   s3://<prefix>-<アカウントID>-<リージョン>-an/akita/landing/opendata/<データセット名>/<ファイル>
#   s3://.../akita/landing/opendata/manifest.json   (取得元・ライセンス・飛ばしたものと理由)
#
# 先に ./scripts/fetch_akita_opendata.py で取得しておく。
#
# 使い方:
#   ./scripts/upload_opendata_landing.sh                 # terraform/.prof.local のプロファイルを使う
#   AWS_PROFILE=xxx ./scripts/upload_opendata_landing.sh
#   ./scripts/upload_opendata_landing.sh --dryrun        # aws s3 sync のオプションをそのまま渡せる
#
# 既存の population_by_age/(Terraform 管理)には触らない。--delete は既定では付けない。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/data/akita_opendata"
REGION="${AWS_REGION:-ap-northeast-1}"
NAME_PREFIX="${NAME_PREFIX:-jaws-festa-2026}"

if [[ -z "${AWS_PROFILE:-}" && -f "$ROOT/terraform/.prof.local" ]]; then
  AWS_PROFILE="$(cat "$ROOT/terraform/.prof.local")"
  export AWS_PROFILE
fi

if [[ ! -f "$SRC/manifest.json" ]]; then
  echo "$SRC/manifest.json が無い。先に ./scripts/fetch_akita_opendata.py を実行する" >&2
  exit 1
fi

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${NAME_PREFIX}-${ACCOUNT}-${REGION}-an"
DEST="s3://${BUCKET}/akita/landing/opendata/"

echo "sync $SRC -> $DEST" >&2
aws s3 sync "$SRC/" "$DEST" --region "$REGION" --exclude ".*" --exclude "*/.*" "$@"
