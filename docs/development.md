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
- `flux` CLI (required for `make controller` and `make package`/`make source`; the version is pinned by `FLUX_VERSION` in `.devcontainer/Dockerfile`, and the devcontainer installs it)
- `docker`, `kind`, `helm`, `kubectl`, `ocm`, `jq` and `tar` for the offline target targets (`make target`, `make target-bootstrap`, `make target-transfer`, `make target-deploy`); `make source` and `make package` need internet access (see [Air-gapped target](bootstrap.md))
- Docker Hub access for `make build` and `make test` (to resolve `nginx:1.31-alpine`)

The tests are validated against the OCM CLI versions listed in `test/ocm-versions.tsv`; on any other version the version-specific tests SKIP (see [OCM version validation](#ocm-version-validation)).

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
make source         # online: write build/bootstrap-bundle when missing or stale, after build and sign (see docs/bootstrap.md)
make package        # online: always rewrite build/bootstrap-bundle: the bundle CTF (external resources inlined), charts, Flux manifests, platform image archives (amd64 and arm64), image list and public key; run make build sign first (requires helm, flux)
make target         # offline: target-bootstrap, target-transfer and target-deploy from the bundle; leaves everything running
make target-cluster    # create the ocm-bootstrap kind cluster, the stand-in for the site's cluster; reuses it when it exists
make target-bootstrap  # offline: create the cluster when missing, load the platform images, start the registry, install the controller stack
make target-transfer   # offline: transfer the component into the target registry
make target-deploy     # offline: deploy the application from the target registry and check it
make target-down    # delete the ocm-bootstrap kind cluster and the registry
make up             # make source, then make target
make bootstrap      # make source, then target-bootstrap only: a ready environment for target-transfer and target-deploy
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
make normalisation   # show the jsonNormalisation/v4alpha3 form of the application descriptor, compare it with ocm sign --dry-run, and show digest changes for label and blob variants; offline
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

Every kind cluster in this repository is created from one pinned node image, `KIND_NODE_IMAGE` in `scripts/cluster.sh` (`kindest/node:v1.37.0@sha256:…`). That covers `make cluster-up` and `make e2e` (the CI `e2e (cli)` leg), `make controller`, and the air-gapped `targetctl.sh bootstrap`. The pin is the image kind v0.33.0 uses by default, so clusters are the same as before it was pinned, now by digest. `bash scripts/cluster.sh node-image` prints it. Renovate updates it; a bump must stay a node image that the release notes of the pinned `KIND_VERSION` list.

The `e2e.sh` script automatically detects whether the cluster existed before this run and only tears it down if this run created it. This allows reusing pre-existing clusters in CI environments.

`make controller` is separate from `make e2e`. It uses its own kind cluster, `ocm-controller`, and deploys the published component from `ghcr.io/lioramilbaum/ocm` through the OCM controllers, kro and Flux. It needs internet access and a published component with the `hello-world-rgd` and `hello-world-kustomize` resources, and CI does not run it. See [Controller stack](controller.md).

The air-gapped path runs the same controller stack with no internet access on the target. `make source` (`sourcectl.sh bundle`) is its only online step: it writes `build/bootstrap-bundle`, platform images included. On the target, `targetctl.sh bootstrap` prepares the environment (cluster, platform images, registry, controller stack), `targetctl.sh transfer` puts the component into the registry and `targetctl.sh deploy` deploys the application; `make target` runs all three and `make up` runs `make source` first. None of them names an internet host. The `e2e (controller)` leg of CI runs bootstrap, transfer and deploy with the egress block in place. See [Air-gapped target](bootstrap.md).

## Version management

Renovate bumps `OCM_CLI_VERSION` together with both `OCM_SHA256_LINUX_AMD64` and `OCM_SHA256_LINUX_ARM64` in a single PR, using the `github-release-attachments` datasource and `# renovate: ocm-linux-<arch> <version>` marker comments in the Dockerfile.

Renovate likewise bumps `FLUX_VERSION` in the Dockerfile and `scripts/controller.sh` together with both `FLUX_SHA256_LINUX_AMD64` and `FLUX_SHA256_LINUX_ARM64`, using `github-release-attachments` and `# renovate: flux-linux-<arch> <version>` markers in the Dockerfile.

Renovate likewise bumps `KIND_VERSION` together with both `KIND_SHA256_LINUX_AMD64` and `KIND_SHA256_LINUX_ARM64`, using `github-release-attachments` and `# renovate: kind-linux-<arch> <version>` markers in the Dockerfile.

## OCM version validation

The tests are validated against the OCM CLI versions in `test/ocm-versions.tsv`, one row per version. A row records the behaviour that has changed between OCM releases and that the tests assert:

| Column | Behaviour | Tests |
|---|---|---|
| `default_norm` | normalisation algorithm of new signatures and component-reference digests | `readme documents signing and verification`, `product references application`, `pki signature is pem encoded`, `pki show reports chain`, `gpg signature is openpgp`, `gpg show reports key`, `normalisation rejects legacy v1` |
| `v1_sign_rejection` | error text of `ocm sign cv --normalisation jsonNormalisation/v1` | `normalisation rejects legacy v1` |
| `plugin_tampered` | `<ocm>,<check>` columns of the plugin `tampered-content` scenario | `plugin scenarios malformed response` |
| `git_tree_mismatch` | `scripts/git.sh download` reason for a commit with a different tree | `git digest covers tree not commit` |
| `tsa_label_transfer` | `ok` or `fail`: transfer of a TSA-timestamped GPG component (upstream label bug) | `gpg timestamp survives transfer` |

A row's `version` must equal the string `ocm version` prints exactly (after stripping a leading `v`), including any pre-release or build suffix: a release candidate such as `0.24.0-rc.1` needs its own row.

These tests read their expectation from the row of the installed `ocm version` (`_ocm_expect` in `test/run.sh`). On a version without a row:

- the version-specific tests report SKIP (`skip: OCM <version> not validated`), and `make test` prints `NOTE: OCM <version> not validated` above the results;
- all other tests run as usual, so the `test` CI job stays green unless something else broke;
- `make ocm-version-check` fails with `OCM <version> not validated: add expectations to test/ocm-versions.tsv`. CI runs it in the separate `ocm-version-validated` job, which turns red on the pull request.

`ocm-version-validated` is informational and must not be a required status check. `main` has no branch protection or rulesets today, so no check is required. If you add them, require `test` and the E2E jobs, not `ocm-version-validated`.

When Renovate bumps `OCM_CLI_VERSION` to a version without a row:

1. Do not push to the Renovate branch. Check it out locally and run `make test` in its devcontainer.
2. For each column, check the behaviour of the new version in the tests listed above, and add a row for it to `test/ocm-versions.tsv`. Keep the existing rows: `main` still runs the old version until the Renovate PR merges. If OCM changed something else, fix that test. If behaviour that a test asserts differs between versions, add a column and read it with `_ocm_expect` at the top of the test.
3. `make ocm-version-check lint test` must pass with the new version and report no `not validated` note.
4. Commit the row (and any test or doc changes) on a branch from `main` and open a separate PR. After it merges, Renovate rebases its PR and `ocm-version-validated` turns green.

Rows for older versions can stay. Remove a row when a new column would need a value that you can no longer check.

## Running tests

```bash
make test  # run the test suite
```

Tests include:
- Air-gapped controller path: `rgd is valid kro simple schema`, `controller rbac grants controller rgd read`, `deploy resources ship in component`, `controller.sh install uses offline sources`, `controller.sh apply localizes deploy manifest with guards`, `controller.sh check waits on app label`, `cluster.sh passes kind config`, `sourcectl bundle writes offline bundle`, `sourcectl bundle writes image archives`, `sourcectl check detects changed platform pins`, `targetctl cluster creates stand-in cluster`, `targetctl bootstrap uses existing cluster`, `targetctl bootstrap loads platform images from the bundle`, `targetctl bootstrap rejects mislabeled archive`, `targetctl bootstrap fails on unstaged image`, `targetctl bootstrap fails on failed import`, `targetctl bootstrap re-imports a missing image once`, `targetctl bootstrap prepares environment only`, `targetctl transfer rejects external resources`, `targetctl transfer publishes verified component`, `targetctl deploy applies application from registry`, `targetctl deploy rejects tampered manifest`, `targetctl transfer and deploy require bootstrap`, `targetctl deploy requires transferred component`, `targetctl up runs bootstrap transfer deploy and leaves it running`, `targetctl offline subcommands run behind offline proxy`, `targetctl bootstrap no_proxy ipv6 api`, `bootstrap verify config quotes key path`, `sourcectl bundle refuses dir outside build`, `make bootstrap rebuilds stale bundle`, `sourcectl chart refs come from controller`, `sourcectl and targetctl stay on their side`, `bootstrap registry image matches registry demo`, `make bootstrap targets`, `make up runs source before target`, `e2e workflow runs controller leg with targetctl`, `docs document bootstrap`, `no stale bootstrap manifest names`, `transfer config routes inlined images`
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
- Pinned runners: `workflows pin runner image`
- Resource access types: `resource access types`, `readme documents resource access types`
- Publish copies resources: `publish copies resources as OCI artifacts`, `publish rejects missing repo and config`, `publish uploaders match deprecated flags`
- Transfer plans: `transfer without copy-resources keeps external reference`, `transfer copy-resources inlines image as local blob`, `transfer copy-resources uploads OCI artifact`
- Canonical component repositories (CTF): `ctf layout is canonical`, `ctf archive is portable and signed`, `readme documents canonical component repositories`
- Kubernetes controller: `readme documents kubernetes controller`
- Controller stack script (`make controller`): `controller.sh run deletes cluster it created`, `controller.sh run keeps cluster with KEEP_CLUSTER`, `controller.sh run reuses existing cluster`, `controller.sh down deletes cluster`, `controller.sh rejects unknown subcommand`, `controller.sh apply sets target architecture`, `controller.sh apply rejects renamed targets`, `controller.sh apply matches backslash values`, `controller.sh check fails without answer`, `controller.sh install requires tools`
- Renovate configuration: `renovate updates OCM SHA256 ARGs`, `renovate updates Flux SHA256 ARGs`, `renovate updates kind SHA256 ARGs`, `renovate updates kind node image`, `renovate managers match their targets`, `renovate captures pinned versions`, `renovate regexes reject invalid input`, `renovate extractVersion maps release tags`, `renovate groups Flux updates`
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
- OCM version validation: `ocm versions table is well formed`, `ocm version check rejects unlisted`, `ocm version check accepts validated`, `ocm version-specific tests skip unlisted`, `ci checks ocm version separately`, `docs document ocm version validation`

## CI

CI runs on `ubuntu-26.04` (linux/amd64) inside the devcontainer. Every job, including the `renovate.yaml` job, pins that runner image rather than `ubuntu-latest`, so a GitHub image switch cannot change CI unannounced. Renovate opens a PR when a newer `ubuntu-*` runner is available. Three workflows build and test:

- **`ci.yaml`** — runs on every push and pull request to `main`: lint and unit tests (`test` job), and the non-blocking `ocm-version-validated` job (`make ocm-version-check`, see [OCM version validation](#ocm-version-validation)).
- **`release.yaml`** — triggered by a `v*.*.*` tag or `workflow_dispatch` with a semver `version` input. Runs tests, then builds and signs the OCM component with `OCM_SIGNING_KEY`, uploads a `application-ctf` artifact, and on tags publishes the component to `ghcr.io/<owner>/ocm` and creates a GitHub release.
- **`e2e.yaml`** — runs on every push and pull request to `main`. A `build` job builds, signs and verifies the component with an auto-generated dev key and uploads it (`application-ctf-dev`). A `package` job (`needs: build`) downloads that artifact, writes the bootstrap bundle (the only online step of the air-gapped path, platform images included), prints its size and uploads it (`application-bootstrap-bundle`), so a bundle failure fails only that job. An `e2e` job (`needs: [build, package]`) runs whenever `build` succeeded and has two legs, `e2e (cli)` and `e2e (controller)`, with `fail-fast: false`. If the bundle is missing, the `controller` leg fails before downloading the bundle and the `cli` leg still runs. Before the block, the `cli` leg creates the kind cluster and pre-pulls the rendered manifest images into the nodes; the `controller` leg only creates the stand-in kind cluster (`make target-cluster`), because the kind node entrypoint resolves `host.docker.internal` over DNS. Both legs create their clusters from the pinned `kindest/node` image in `scripts/cluster.sh` (the kind v0.33.0 default, updated by Renovate). Both then block new outbound connections from the kind network with an iptables `DOCKER-USER` rule and start a `tcpdump` capture on the kind bridge. Inside the block, the `cli` leg runs `make e2e-run` and checks the pod, and the `controller` leg runs `make target-bootstrap`, `make target-transfer` and `make target-deploy` as three steps, all from the bundle. Each leg then removes the rule, stops the capture, and fails if any packet left the private ranges for the public internet. Each pcap and tcpdump text is uploaded as the `application-e2e-egress-evidence-<leg>` artifact.

Required repository secrets: `OCM_SIGNING_KEY` (RSA private key PEM).

## Notes

- `make build` and `make test` require Docker Hub access to resolve `nginx:1.31-alpine`. If Docker Hub is unavailable, builds will fail.
