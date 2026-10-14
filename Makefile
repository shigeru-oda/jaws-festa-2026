.DEFAULT_GOAL := help
UV := uv run

.PHONY: help sync check tf-check clean opendata-fetch opendata-fetch-all opendata-upload opendata-local

help: ## このヘルプを表示する
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

sync: ## 依存を入れる(標準ライブラリだけなので実質不要)
	uv sync

check: ## 年齢各歳 CSV の列構成と、列ずれの期待値を検査する(AWS 認証情報は不要)
	./scripts/fetch_nenreikakusai.sh --check
	./scripts/verify_drift.py --check

tf-check: ## Terraform を整形チェック + 検証する(AWS 認証情報は不要)
	cd terraform && terraform fmt -check -recursive && terraform validate

opendata-fetch: ## 秋田県オープンデータの CSV を全部 data/akita_opendata/ に取得する(50MB 超は飛ばす)
	./scripts/fetch_akita_opendata.py

opendata-fetch-all: ## 上と同じだが、地震被害想定(1本 120MB 前後 x 27本・3.4GB)も取得する
	./scripts/fetch_akita_opendata.py --max-mb 0

opendata-upload: ## data/akita_opendata/ を landing(akita/landing/opendata/)へ上げる(AWS 認証が要る)
	./scripts/upload_opendata_landing.sh

opendata-local: ## landing→bronze→HTML のノートブック3本を AWS に触らず手元で実行する(work/opendata/)
	rm -rf work/opendata && mkdir -p work/opendata/bucket/akita/landing
	# macOS(APFS)では -c で複製せず参照だけ作る(地震被害想定を含めると 3.4GB あるため)。使えなければ普通にコピー
	cp -Rc data/akita_opendata work/opendata/bucket/akita/landing/opendata 2>/dev/null \
	  || cp -R data/akita_opendata work/opendata/bucket/akita/landing/opendata
	cp notebooks/opendata_landing_to_bronze.ipynb notebooks/opendata_bronze_report.ipynb notebooks/opendata_akita_story.ipynb work/opendata/
	cd work/opendata && OPENDATA_LOCAL_ROOT=bucket DRY_RUN=0 uv run --no-project --with jupyter==1.1.1 --with nbconvert==7.16.6 \
	  jupyter nbconvert --to notebook --execute --inplace opendata_landing_to_bronze.ipynb opendata_bronze_report.ipynb opendata_akita_story.ipynb
	@echo "-> work/opendata/opendata_report/index.html"
	@echo "-> work/opendata/akita_report/index.html"

clean: ## 作業ディレクトリを消す(out/ は一次情報なので消さない)
	rm -rf work
