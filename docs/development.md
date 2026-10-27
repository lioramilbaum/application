# Development

## Prerequisites

- OCM CLI v2 ≥ 0.17.0 (publishing with `OCM_REGISTRY_USERNAME`/`OCM_REGISTRY_PASSWORD` requires ≥ 0.19.1); `make versions`, `make wget` and `make git` require ≥ 0.19.0; the OCIImageLayer/v1 layer step of `make registry` (`scripts/registry.sh layer`) and the timestamp subcommand of `make gpg` (`scripts/gpg.sh timestamp`) require ≥ 0.21.0
- kind
- `make`
- `shellcheck` (for linting)
- `jq`
- `python3` (for `make build`: `components/hello-world/flux-artifact.py` generates the Flux OCI artifact; `make oci`: `components/oci/layout.py` writes the layout tars; `make wget`, `make credentials`, and `make plugin`: the local upstream and recording servers, the demo-store plugin (Python 3.9+ stdlib only), and their readiness/probe checks; `make test`: test helpers)
- `openssl` (`make pki` uses `openssl ca` to issue demo certificates; tested with OpenSSL 3.0 and 4.0 and LibreSSL 3.3)
- `curl` (for `make wget`, `make credentials`, and `make plugin`: readiness and probe checks)
- `git` 2.32 or newer (for `make git`: creates the demo repository and reads it back)
- `gpg` (GnuPG 2.2 or newer, for `make gpg`; `scripts/gpg.sh timestamp` also needs `openssl` and `python3` for its local TSA, and OCM ≥ 0.21.0)
- `tar` (for `make oci`: reads the layers back)
- `kubectl` (for deploying and for `make manifests`, which uses `kubectl kustomize`)
- `helm` is optional for `make helm` (only for rendering the downloaded chart with `helm template`) but required for `make controller`
- `docker` (for `make e2e` or `make e2e-run` only, and for `make registry`)
- `flux` CLI v2.9.6 (required for `make controller` only; the devcontainer installs it)
- Docker Hub access for `make build` and `make test` (to resolve `nginx:1.31-alpine`)

OCM CLI and kind are provided by the devcontainer image. Outside the devcontainer, put `ocm` and `kind` on your PATH.

The `.devcontainer/` directory provides all required tools when used with Docker Desktop or a compatible Docker host and devcontainers CLI.

## Lifecycle

```bash
make build           # build the OCM component archive (CTF)
make sign            # sign with an auto-generated dev RSA key
make verify          # verify the signature
make transfer-plan OCM_REPO=<target>  # review before publishing
make resolvers       # write build/resolvers.ocmconfig mapping github.com/lioramilbaum/** to the local CTF
make manifests       # download and render app manifests from the component
make deploy          # deploy the application to the current cluster (requires KUBECONFIG)
make cluster-up      # create or reuse the kind cluster; writes build/e2e/kubeconfig (requires docker)
make e2e-run         # run e2e against an existing cluster
make cluster-down    # delete the kind cluster
make e2e             # spin up kind cluster, deploy, verify pod ready, tear down (requires docker)
make controller      # create or reuse the ocm-controller kind cluster, install OCM controllers, kro and Flux, deploy the published component and check the pod (requires docker, helm, flux; KEEP_CLUSTER=1 keeps it; see docs/controller.md)
make publish OCM_REPO=ghcr.io/<you>/ocm  # transfer to an OCI registry, copying external resources (e.g. the nginx image) as OCI artifacts; optional OCM_REGISTRY_USERNAME/OCM_REGISTRY_PASSWORD
make ownership       # build the ownership demo component and trace the owner of each resource
make sbom            # regenerate the CycloneDX SBOM (build/sbom/hello-world.cdx.json); also run by make build
make product         # build, sign and verify the product component that references the application
make versions  # build the versions demo and show constraint/--latest/scheme selection
make credentials  # build and show credential matching; offline
make helm      # build, sign, verify and download the Helm chart demo (helm/v1 input, --transformer helm); offline
make wget      # build, sign, verify and download the HTTP resources demo (Wget/v1 input and access); offline, requires OCM >= 0.19.0
make pki        # create a demo CA, build, sign with a PEM certificate-chain signature and verify against the root CA; offline
make git        # build, sign, verify and audit the Git source demo (Git/v1 source, access and input); offline, requires OCM >= 0.19.0
make gpg        # build, sign, verify and download the GPG (OpenPGP) signing demo; offline; `bash scripts/gpg.sh timestamp` adds an RFC 3161 timestamp from a local TSA (OCM >= 0.21.0)
make oci        # build, sign, verify and download the OCI image demo (ociImage from local OCI layout, multi-arch index); offline, requires python3 and tar
make plugin     # install the demo-store plugin, build, download through it and show its capabilities; offline (requires python3, curl)
make registry   # start a local registry, push, sign, verify, pull and show the demo component, then the OCIImageLayer/v1 layer demo (OCM >= 0.21.0); requires Docker
make graph      # build a three-level component graph (platform, frontend and backend, runtime) across three CTFs; show get cv --recursive, resolver order, flat vs recursive transfer and tamper detection; offline
make github     # build, sign, verify, download and transfer the GitHub/v1 demo against a local GitHub REST API emulator; offline, requires python3 and curl
make normalisation   # show the jsonNormalisation/v4alpha1 form of the application descriptor, compare it with ocm sign --dry-run, and show digest changes for label and blob variants; offline
make s3          # start a local S3-compatible server, build, sign, verify and download the S3/v1 and S3/v2 demo; requires Docker (stop with: bash scripts/s3.sh stop)
make none-access # build, sign and verify a component with a None-access resource; show that its digest is not signed, that download fails gracefully and how the signed label binds the external bytes; offline
```

## E2E testing

The `make e2e` target creates an isolated kind cluster (named `ocm-application`) using a dedicated kubeconfig at `build/e2e/kubeconfig`, deploys the application, verifies the pod is ready and responds to requests, then tears down the cluster. To keep the cluster running for manual inspection:

```bash
make e2e KEEP_CLUSTER=1
# Cluster remains running; export KUBECONFIG=build/e2e/kubeconfig to interact
# To delete: kind delete cluster --name ocm-application
```

For advanced scenarios (e.g., CI with a pre-provisioned cluster), use the separate targets:

```bash
make cluster-up      # Create or reuse the ocm-application cluster
make build sign      # Build and sign the component
make e2e-run         # Run e2e tests against the cluster (only tears down if it created the cluster)
make cluster-down    # Delete the cluster
```

The `e2e.sh` script automatically detects whether the cluster existed before this run and only tears it down if this run created it. This allows reusing pre-existing clusters in CI environments.

`make controller` is separate from `make e2e`. It uses its own kind cluster, `ocm-controller`, and deploys the published component from `ghcr.io/lioramilbaum/ocm` through the OCM controllers, kro and Flux. It needs internet access and a published component with the `hello-world-rgd` and `hello-world-kustomize` resources, and CI does not run it. See [Controller stack](controller.md).

## Version management

Renovate bumps `OCM_CLI_VERSION` together with both `OCM_SHA256_LINUX_AMD64` and `OCM_SHA256_LINUX_ARM64` in a single PR, using the `github-release-attachments` datasource and `# renovate: ocm-linux-<arch> <version>` marker comments in the Dockerfile.

Renovate likewise bumps `FLUX_VERSION` in the Dockerfile and `scripts/controller.sh` together with both `FLUX_SHA256_LINUX_AMD64` and `FLUX_SHA256_LINUX_ARM64`, using `github-release-attachments` and `# renovate: flux-linux-<arch> <version>` markers in the Dockerfile.

`KIND_SHA256_*` ARGs are still updated by hand when Renovate bumps `KIND_VERSION`.

## Running tests

```bash
make test  # run the test suite
```

Tests include:
- Component structure and resource metadata
- Signature verification with correct and wrong keys
- Manifest rendering with digest-pinned images
- Localization rules: resource metadata (`localization resource metadata`), rule-based image injection (`manifests localizes by rule not placeholder`), rejection of untargeted rules (`manifests rejects untargeted localization`), wrong container (`manifests rejects wrong container`), and tampered rules (`manifests rejects tampered localization`)
- Deploy-time configuration: resource metadata (`config resource metadata`), value injection (`manifests applies config values`), rejection of tampered config (`manifests rejects tampered config`), untargeted config (`manifests rejects untargeted config`), and invalid config (`manifests rejects invalid config`)
- Deploy workflow and error handling
- Script resource download and bundle self-containedness
- Component reference override: `cv_ref honours OCM_COMPONENT_REPO`, `manifests reads from OCM_COMPONENT_REPO`
- Transferred images: `manifests localizes transferred image`, `manifests rejects mismatched image digest`, `manifests rejects missing image digest`
- Local registry mirror for kind nodes: `cluster.sh configures local registry mirror`
- CI e2e isolation: `e2e workflow isolates deploy`
- Resource access types: `resource access types`, `readme documents resource access types`
- Publish copies resources: `publish copies resources as OCI artifacts`, `publish rejects missing repo and config`, `publish uploaders match deprecated flags`
- Transfer plans: `transfer without copy-resources keeps external reference`, `transfer copy-resources inlines image as local blob`, `transfer copy-resources uploads OCI artifact`
- Canonical component repositories (CTF): `ctf layout is canonical`, `ctf archive is portable and signed`, `readme documents canonical component repositories`
- Kubernetes controller: `readme documents kubernetes controller`
- Controller stack script (`make controller`): `controller.sh run deletes cluster it created`, `controller.sh run keeps cluster with KEEP_CLUSTER`, `controller.sh run reuses existing cluster`, `controller.sh down deletes cluster`, `controller.sh rejects unknown subcommand`, `controller.sh apply sets target architecture`, `controller.sh check fails without answer`, `controller.sh install requires tools`
- Renovate configuration: `renovate updates OCM SHA256 ARGs`, `renovate updates Flux SHA256 ARGs`, `renovate managers match their targets`, `renovate captures pinned versions`, `renovate regexes reject invalid input`, `renovate extractVersion maps release tags`, `renovate groups Flux updates`
- Kubernetes deployer: `readme documents kubernetes deployer`
- Plugin system: `builtin plugins serve component types`, `readme documents plugin system`, demo plugin: `plugin capabilities returns access type`, `plugin healthz responds`, `plugin build registers access type`, `plugin download returns blob`, `plugin identity endpoint`, `plugin missing plugin fails gracefully`, `plugin show lists capabilities`, `plugin scenarios correct response`, `plugin scenarios malformed response`, `plugin loglevel debug shows registration`, `make plugin target`, `readme documents plugin demo`
- Signing and verification: `signature covers normalized descriptor`, `readme documents signing and verification`
- Component identity: `component identity selects artifacts`, `component identity rules enforced`, `readme documents component identity`
- Kubernetes component discovery: `discovery selects image variants`, `readme documents kubernetes component discovery`
- Ownership: `ownership records owner`, `ownership record is deterministic`, `ownership survives transfer`, `ownership trace reports owner`, `readme documents ownership`
- Helm charts: `helm chart resource metadata`, `helm chart is oci artifact`, `helm transformer extracts chart`, `helm download verifies chart`, `helm download requires signature`, `helm build from any directory`, `helm chart version independent of component`, `helm chart layer is reproducible`, `helm input rejects invalid chart`, `helm access resolved at build time`, `helm transfer keeps chart local`, `helm values from component`, `helm values requires application ctf`, `helm show reports chart`, `make helm target`, `readme documents helm charts`
- HTTP resources: `wget resource metadata`, `wget pinned digest matches upstream file`, `wget pinned digest rejects mismatch`, `wget input embeds bytes at build time`, `wget access needs server at consume time`, `wget download rejects changed upstream`, `wget download requires signature`, `wget checksum require rejects unadvertised`, `wget checksum matrix`, `wget rejects invalid checksum mode`, `wget credentials resolved by url identity`, `wget transfer reference vs copy`, `wget transfer copy enforces digest`, `wget requires ocm 0.19`, `wget server port in use`, `wget show reports resources`, `make wget target`, `readme documents http resources`
- Certificate-chain signing: `pki signature is pem encoded`, `pki verifier pins only root`, `pki scenarios`, `pki rotation keeps verifier config`, `pki certs are reused`, `pki reissues expiring leaf`, `pki signature covers descriptor`, `pki signature survives transfer`, `pki verify requires signature`, `pki own pki requires all vars`, `pki own pki uses supplied files`, `pki show reports chain`, `make pki target`, `readme documents certificate-chain signing`
- GPG signing timestamps (need OCM >= 0.21.0 and a local TSA): `gpg timestamp rfc3161`, `gpg timestamp survives transfer`
- Git repositories: `git resource metadata`, `git ref pinned at build time`, `git upstream is deterministic`, `git snapshot matches commit tree`, `git digest covers tree not commit`, `git signature binds commit label`, `git audit matches snapshot`, `git audit rejects wrong commit label`, `git audit requires signature`, `git scenarios`, `git transfer carries snapshot only`, `git uploader cannot copy git access`, `git own repo requires both vars`, `git own repo uses supplied repository`, `git rejects sha256 repository`, `git requires ocm 0.19`, `git show reports provenance`, `make git target`, `readme documents git repositories`
- OCI images: `oci layout is reproducible`, `oci image resource metadata`, `oci resource digest is manifest digest`, `oci download yields oci layout`, `oci multiarch index references variants`, `oci download requires signature`, `oci signature covers image digest`, `oci transfer plan copy-resources leaves local images`, `oci transfer plan uploader rewrites references`, `oci transfer to ctf keeps digests`, `oci inspect reports architectures`, `localization relocate rewrites access keeps digest`, `localization readme documents three levels`, `make oci target`, `readme documents oci images`
- Version selection: `versions lists newest first`, `versions constraint filters`, `versions latest includes prereleases by default`, `versions scheme orders build numbers`, `versions without scheme misorders`, `versions reference requires semver`, `versions requires ocm 0.19`, `versions show reports selection`, `make versions target`, `readme documents version selection`, `docs versions page`
- Credential system: `credentials build creates ctf`, `credentials show lists consumer types`, `credentials match exact wins over wildcard`, `credentials match wildcard catches subpath`, `credentials match path star does not cross slash`, `credentials chain combines configs`, `credentials wget identity hostname required`, `credentials wget identity port attribute`, `credentials generic config wraps multiple`, `credentials scenarios matrix output`, `make credentials target`, `readme documents credential system`
- Local OCI registry: `registry start creates container`, `registry push component`, `registry get cv from registry`, `registry sign in registry`, `registry verify signed component`, `registry pull downloads resource`, `registry stop removes container`, `registry push idempotent`, `registry transfer preserves resources`, `registry unsigned verify fails`, `registry oci url format`, `registry layer resolves blob by digest`, `registry layer copy becomes local blob` (these report SKIP without Docker); `registry docker available`, `make registry target` and `readme documents local oci registry` always run
- Component graphs: `graph references span three repositories`, `graph recursive get walks all levels`, `graph resolver order first match wins`, `graph recursive transfer collects graph`, `graph flat transfer is not self contained`, `graph plan uploads shared reference once`, `graph transfer detects changed transitive reference`, `make graph target`, `readme documents component graphs`
- Component references: `docs product page`
- GitHub access: `github archive is deterministic`, `github access pinned at build time`, `github download matches digest`, `github ref moved keeps pinned commit`, `github download rejects rewritten archive`, `github access needs api at consume time`, `github transfer copy inlines archive`, `github server port in use`, `github online is opt in`, `github online release asset` (SKIP unless `OCM_ONLINE_TESTS=1`), `make github target`, `readme documents github access`
- Signing normalisation: `normalisation matches ocm digest`, `normalisation excludes unsigned fields`, `normalisation label vs blob digests`, `normalisation reimplementation matches each variant`, `normalisation rejects legacy v1`, `make normalisation target`, `readme documents signing normalisation`
- S3 resources: `s3 image pinned by digest`, `s3 docker skip without docker`, `s3 seed uploads object`, `s3 access records endpoint`, `s3 access v1 uses bucket key fields`, `s3 access v2 uses bucket name fields`, `s3 unversioned build warns no pin`, `s3 versioned bucket pins version`, `s3 input becomes local blob`, `s3 download v1 and v2`, `s3 download rejects overwritten object`, `s3 pinned version survives overwrite`, `s3 input works offline`, `s3 credentials required`, `s3 glob star matches`, `s3 glob doublestar matches`, `s3 transfer copies v2 only`, `s3 stop removes container`, `make s3 target`, `readme documents s3 resources` (these report SKIP without Docker, except the static checks)
- Resources without access (None): `none-access sha256 matches constructor label`, `none-access resource has no digest in descriptor`, `none-access build warns no digest processor`, `none-access control resource downloads`, `none-access download fails gracefully`, `none-access sign and verify`, `none-access digest not signed`, `none-access digest triggers warning`, `none-access lowercase warns missing digest`, `none-access versioned type is not none`, `none-access identity is signed`, `none-access label is signed`, `none-access audit passes`, `none-access audit detects tamper`, `none-access transfer keeps none`, `none-access copy resources keeps none`, `make none-access target`, `readme documents none access`
- README index: `readme intro lists demos`
- Repository metadata: `license is apache 2.0`, `contributing guide covers workflow`

## CI

CI runs on `ubuntu-latest` (linux/amd64) inside the devcontainer across three workflows:

- **`ci.yaml`** — runs on every push and pull request to `main`: lint and unit tests.
- **`release.yaml`** — triggered by a `v*.*.*` tag or `workflow_dispatch` with a semver `version` input. Runs tests, then builds and signs the OCM component with `OCM_SIGNING_KEY`, uploads a `application-ctf` artifact, and on tags publishes the component to `ghcr.io/<owner>/ocm` and creates a GitHub release.
- **`e2e.yaml`** — runs on every push and pull request to `main`. A `package` job builds and signs the component with an auto-generated dev key and uploads it. A `deploy` job downloads it, verifies the signature, and runs the e2e in isolation: it creates the kind cluster and pre-pulls the rendered manifest images into the kind nodes, then blocks new outbound connections from the kind network with an iptables `DOCKER-USER` rule and starts a `tcpdump` capture on the kind bridge. It runs `make e2e-run` against the cluster, then removes the rule, stops the capture, and fails if any packet left the private ranges for the public internet. The pcap and tcpdump text are uploaded as the `application-e2e-egress-evidence` artifact.

Required repository secrets: `OCM_SIGNING_KEY` (RSA private key PEM).

## Notes

- `make build` and `make test` require Docker Hub access to resolve `nginx:1.31-alpine`. If Docker Hub is unavailable, builds will fail.
