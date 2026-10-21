VERSION        ?= 0.1.0
OCM            ?= ocm

export VERSION OCM

.PHONY: help build sign verify resolvers manifests deploy publish transfer-plan ownership sbom product versions helm wget pki git gpg oci credentials plugin registry controller graph github normalisation s3 none-access lint test e2e cluster-up cluster-down e2e-run clean

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
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

pki: ## Create a demo CA, build, sign (PEM certificate chain) and verify the PKI demo against the root CA; offline
	@bash scripts/pki.sh

git: ## Create a demo Git repository, build, sign, verify and audit the Git source demo (Git/v1 source, access and input); offline (requires OCM CLI >= 0.19.0, git)
	@bash scripts/git.sh

gpg: ## Create throwaway GPG keys, build, sign (OpenPGP), verify and download the GPG signing demo (GPG/v1alpha1 signature); offline (requires gpg 2.2 or newer, jq)
	@bash scripts/gpg.sh

oci: ## Build, sign, verify and download the OCI image demo (ociImage from local OCI layout, multi-arch index); offline
	@bash scripts/oci.sh

credentials: ## Build the credentials demo and show consumer identity matching (exact vs wildcard, path, Wget attributes) against a local recording server; offline (requires python3, curl)
	@bash scripts/credentials.sh

plugin: ## Install the demo-store Python plugin, build the plugin demo (demo-store/v1alpha1 access type served by an external plugin), download through it and show its capabilities; offline (requires python3, curl)
	@bash scripts/plugin.sh

registry: ## Start a local registry:2 on 127.0.0.1:5055, push (ocm transfer cv), sign, verify, pull and show the registry demo; requires Docker (skips without it); stop with: bash scripts/registry.sh stop
	@bash scripts/registry.sh

controller: ## Create or reuse the ocm-controller kind cluster, install OCM controllers, kro and Flux, deploy the published component (OCM_CONTROLLER_REPO=ghcr.io/lioramilbaum/ocm) via NamespacedDeployer + kro + Flux and check the pod answers; KEEP_CLUSTER=1 keeps it (requires docker, helm, flux, kind; stop with: bash scripts/controller.sh down)
	@bash scripts/controller.sh

graph: ## Build a three-level component graph across three CTFs (platform → frontend/backend → runtime), show get cv --recursive, resolver order, flat vs recursive transfer and transitive digest enforcement; offline
	@bash scripts/graph.sh

github: ## Build, sign, verify, download and transfer the GitHub/v1 access demo against a local GitHub REST API emulator; offline (requires python3, curl). GITHUB_DEMO_ONLINE=1 bash scripts/github.sh online uses github.com
	@bash scripts/github.sh

normalisation: build ## Print the jsonNormalisation/v4alpha1 form of the application descriptor, compare it against ocm sign --dry-run, and show resource/component digest changes across label and blob mutations; offline
	@bash scripts/normalisation.sh

s3: ## Start a local S3-compatible server (rustfs) on 127.0.0.1:19000, seed buckets, build, sign, verify and download the S3/v1 and S3/v2 access demo (version pinning, digest mismatch, input vs access, --copy-resources); requires Docker (skips without it) and curl >= 7.75; stop with: bash scripts/s3.sh stop
	@bash scripts/s3.sh

none-access: ## Build, sign and verify a component with a None-access resource, show that its digest is stripped before signing, that download fails gracefully, and bind the external bytes with a signed label instead; offline
	@bash scripts/none-access.sh

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
	rm -f components/hello-world/hello-world-kustomize.oci.tar
