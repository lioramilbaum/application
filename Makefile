VERSION        ?= 0.1.0
OCM            ?= $(shell command -v ocm 2>/dev/null || echo bin/ocm)

export VERSION OCM

.PHONY: help tools build sign verify manifests deploy publish lint test e2e clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

tools: ## Download the OCM CLI and kind binary into bin/
	@bash scripts/fetch-ocm.sh
	@bash scripts/fetch-kind.sh

build: ## Build the OCM component archive (CTF)
	@bash scripts/build.sh

sign: ## Sign the component archive
	@bash scripts/sign.sh

verify: ## Verify signatures on the component archive
	@bash scripts/verify.sh

manifests: ## Download and render app manifests from the OCM component
	@bash scripts/manifests.sh

deploy: build sign ## Deploy the application to the current cluster (requires KUBECONFIG)
	@bash scripts/deploy.sh

publish: ## Transfer the CTF to an OCI registry (requires OCM_REPO=...)
	@bash scripts/publish.sh

lint: ## Lint shell scripts (if shellcheck is available)
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh test/run.sh; \
	else \
		echo "shellcheck not installed, skipping shell lint"; \
	fi

test: ## Run the test suite
	@bash test/run.sh

e2e: build sign ## End-to-end test using kind (requires docker)
	@bash scripts/e2e.sh

clean: ## Remove build artifacts
	rm -rf build bin
