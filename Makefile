.DEFAULT_GOAL := help
UV := uv run

.PHONY: help sync check tf-check clean

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

clean: ## 作業ディレクトリを消す(out/ は一次情報なので消さない)
	rm -rf work
