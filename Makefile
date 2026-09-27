.DEFAULT_GOAL := help
UV := uv run

.PHONY: help sync notebooks check verify edit clean tf-check

help: ## このヘルプを表示する
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

sync: ## 依存を入れる
	uv sync

notebooks: ## ノートブックをスクリプトとして通し、out/ を再生成する
	@for nb in akita_iceberg athena_vs_s3tables rename_blindspot akita_now; do \
		printf '%-22s' "$$nb"; \
		if $(UV) python notebooks/$$nb.py > /tmp/nb_$$nb.log 2>&1; then \
			echo "OK"; \
		else \
			echo "FAIL"; tail -20 /tmp/nb_$$nb.log; exit 1; \
		fi; \
	done
	@printf '%-22s' "prefecture_schemas"; \
	if ls data/prefectures/*_population.csv > /dev/null 2>&1; then \
		if $(UV) python notebooks/prefecture_schemas.py > /tmp/nb_pref.log 2>&1; then \
			echo "OK"; \
		else \
			echo "FAIL"; tail -20 /tmp/nb_pref.log; exit 1; \
		fi; \
	else \
		echo "SKIP (data/prefectures/ は再配布しないため未同梱。out/prefecture_comparison.json は既存の実測値を使う)"; \
	fi

check: ## 登壇原稿の数字が out/*.json と一致しているか検査する
	$(UV) python scripts/retime_talk_script.py --check
	$(UV) python scripts/check_talk_numbers.py

verify: notebooks check ## 再生成してから検査する(これが通れば原稿とデータは一致している)
	@echo "--- verify OK ---"

edit: ## marimo を起動して対話的に触る(NB=名前 で指定)
	$(UV) marimo edit notebooks/$(or $(NB),athena_vs_s3tables).py

tf-check: ## Terraform を整形チェック + 検証する(AWS 認証情報は不要)
	cd terraform && terraform fmt -check -recursive && terraform validate

clean: ## 生成物を消す(data/ は消さない)
	rm -rf work out/*.png out/*.json out/*.html
