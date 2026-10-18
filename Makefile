VERSION        ?= 0.1.0
OCM            ?= ocm

export VERSION OCM

.PHONY: help build sign verify resolvers manifests deploy publish transfer-plan ownership sbom product versions helm wget lint test e2e cluster-up cluster-down e2e-run clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

build: ## Build the OCM component archive (CTF)
	@bash scripts/build.sh

sign: ## Sign the component archive
	@bash scripts/sign.sh

verify: ## Verify signatures on the component archive
	@bash scripts/verify.sh

resolvers: ## Write build/resolvers.ocmconfig mapping github.com/lioramilbaum/** to the local CTF
	@bash scripts/resolvers.sh

manifests: ## Download and render app manifests from the OCM component
	@bash scripts/manifests.sh

deploy: build sign ## Deploy the application to the current cluster (requires KUBECONFIG)
	@bash scripts/deploy.sh

publish: ## Transfer the CTF and copy external resources (--copy-resources) to an OCI registry (requires OCM_REPO=...; optional OCM_REGISTRY_USERNAME/OCM_REGISTRY_PASSWORD)
	@bash scripts/publish.sh

transfer-plan: ## Dry-run the publish transfer and write build/transfer-plan.json (requires OCM_REPO=...; optional TRANSFER_CONFIG=transfer.ocmconfig)
	@TRANSFER_PLAN=1 bash scripts/publish.sh

ownership: ## Build and trace the ownership demo component
	@bash scripts/ownership.sh

sbom: ## Generate the CycloneDX SBOM (build/sbom/hello-world.cdx.json); also run by build
	@bash scripts/sbom.sh

product: build sign ## Build, sign, verify and show tree of the product component that references the application
	@bash scripts/product.sh

versions: ## Build the versions demo (release + nightly CTFs) and show constraint, --latest and versioning-scheme selection (requires OCM CLI >= 0.19.0)
	@bash scripts/versions.sh

helm: ## Build, sign, verify and download the Helm chart demo component (helm/v1 input, --transformer helm); offline
	@bash scripts/helm.sh

wget: ## Build, sign, verify and download the HTTP resources demo (Wget/v1 input and access) against a local server; offline (requires OCM CLI >= 0.19.0, python3)
	@bash scripts/wget.sh

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

cluster-up: ## Create or reuse the kind cluster; writes build/e2e/kubeconfig (requires docker)
	@bash scripts/cluster.sh up

cluster-down: ## Delete the kind cluster
	@bash scripts/cluster.sh down

e2e-run: ## Run e2e against an existing cluster (CI: cluster is created as a separate step)
	@bash scripts/e2e.sh

clean: ## Remove build artifacts
	rm -rf build
