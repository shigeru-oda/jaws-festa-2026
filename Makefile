.DEFAULT_GOAL := help
UV := uv run

.PHONY: help sync check tf-check clean opendata-fetch opendata-upload opendata-local

help: ## このヘルプを表示する
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

sync: ## 依存を入れる(標準ライブラリだけなので実質不要)
	uv sync

check: ## 登壇原稿の数字が out/*.json と一致しているか検査する(AWS 認証情報は不要)
	$(UV) python scripts/retime_talk_script.py --check
	$(UV) python scripts/check_talk_numbers.py
	./scripts/fetch_nenreikakusai.sh --check
	./scripts/verify_drift.py --check

tf-check: ## Terraform を整形チェック + 検証する(AWS 認証情報は不要)
	cd terraform && terraform fmt -check -recursive && terraform validate

opendata-fetch: ## 秋田県オープンデータの CSV を全部 data/akita_opendata/ に取得する(50MB 超は飛ばす)
	./scripts/fetch_akita_opendata.py

opendata-upload: ## data/akita_opendata/ を landing(akita/landing/opendata/)へ上げる(AWS 認証が要る)
	./scripts/upload_opendata_landing.sh

opendata-local: ## landing→bronze→HTML のノートブック2本を AWS に触らず手元で実行する(work/opendata/)
	rm -rf work/opendata && mkdir -p work/opendata/bucket/akita/landing
	cp -R data/akita_opendata work/opendata/bucket/akita/landing/opendata
	cp notebooks/opendata_landing_to_bronze.ipynb notebooks/opendata_bronze_report.ipynb work/opendata/
	cd work/opendata && OPENDATA_LOCAL_ROOT=bucket DRY_RUN=0 uv run --no-project --with jupyter==1.1.1 --with nbconvert==7.16.6 \
	  jupyter nbconvert --to notebook --execute --inplace opendata_landing_to_bronze.ipynb opendata_bronze_report.ipynb
	@echo "-> work/opendata/opendata_report/index.html"

clean: ## 作業ディレクトリを消す(out/ は一次情報なので消さない)
	rm -rf work
