.DEFAULT_GOAL := help
UV := uv run

# AWS プロファイル。terraform/.prof.local に控えてあるものを既定で使う。
PROFILE ?= $(shell cat terraform/.prof.local 2>/dev/null)

.PHONY: help sync check athena tf-check clean

help: ## このヘルプを表示する
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

sync: ## 依存を入れる(標準ライブラリだけなので実質不要)
	uv sync

check: ## 登壇原稿の数字が out/*.json と一致しているか検査する(AWS 認証情報は不要)
	$(UV) python scripts/retime_talk_script.py --check
	$(UV) python scripts/check_talk_numbers.py
	./scripts/fetch_jinkousetai.sh --check
	./scripts/fetch_nenreikakusai.sh --check
	./scripts/verify_drift.py --check

athena: ## AWS 上の保存クエリを実行して out/athena_*.json を再生成する(AWS 認証情報が必要)
	@test -n "$(PROFILE)" || { echo "PROFILE が空。make athena PROFILE=<プロファイル名> で渡す"; exit 1; }
	./scripts/run_athena_queries.py --profile "$(PROFILE)" --prefix jinkousetai_
	./scripts/run_athena_queries.py --profile "$(PROFILE)" --prefix drift_

tf-check: ## Terraform を整形チェック + 検証する(AWS 認証情報は不要)
	cd terraform && terraform fmt -check -recursive && terraform validate

clean: ## 作業ディレクトリを消す(out/ は一次情報なので消さない)
	rm -rf work
