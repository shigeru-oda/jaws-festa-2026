# 検証cmdメモ

## 1.「年齢別人口流動調査（県・市町村の年齢各歳、男女別人口）」のdatasetをlocalにdownloadする

```bash
# リポジトリのルートで実行
./data/fetch_nenreikakusai.sh
```

## 2.バケットを作る(アカウントリージョン名前空間)

```bash
REGION=ap-northeast-1
ACCOUNT_ID="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
BUCKET="jaws-festa-2026-${ACCOUNT_ID}-${REGION}-an"

aws s3api create-bucket \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$BUCKET" \
  --bucket-namespace account-regional \
  --create-bucket-configuration LocationConstraint="$REGION"

echo "$BUCKET"
```

## 3.のdatasetをS3にUploadする

s3://BUCKET/akita/landing/population_by_age/

## 4.正規化と英語カラム定義の生成

- 文字コードの判定（UTF-8 BOM付き / CP932）とUTF-8への統一、改行をLFに統一
- 日本語→英語のカラム対応表（column_mapping.csv）の生成

## 5.bronzeテーブルの作成（Athena）
