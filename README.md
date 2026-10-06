# application

A minimal HelloWorld application built with the [Open Component Model](https://ocm.software) (OCM v2), deployed on a kind cluster.

## Component tree

```
github.com/lioramilbaum/application
├── hello-world-image  (ociImage, docker.io/library/nginx:1.27-alpine)
├── hello-world-manifests  (blob, application/yaml, Kubernetes manifests)
├── component-constructor  (blob, application/yaml, OCM component descriptor)
├── script-lib  (blob, text/x-shellscript, shared script functions)
├── script-verify  (blob, text/x-shellscript, signature verification)
├── script-manifests  (blob, text/x-shellscript, download and render manifests)
└── script-deploy  (blob, text/x-shellscript, deploy to Kubernetes)
```

## How it works

A single OCM component with 7 direct resources (no component references):
- **hello-world-image**: nginx container image (digest-pinned from Docker Hub)
- **hello-world-manifests**: Kubernetes Namespace, ConfigMap, Deployment, and Service manifests
- **component-constructor**: OCM component descriptor (for bundled deployments)
- **script-lib, script-verify, script-manifests, script-deploy**: deployment and supporting scripts

The key concept is **digest-pinned images**. At build time, the OCM component references the nginx image as `docker.io/library/nginx:1.27-alpine`. The OCM build system automatically resolves this to the full digest (e.g., `docker.io/library/nginx:1.27-alpine@sha256:abc123...`). At deploy time, `manifests.sh` downloads the manifest template from the signed component and replaces the `HELLO_WORLD_IMAGE` placeholder with the pinned digest from the component descriptor. This ensures reproducible, tamper-evident deployments: the deployed image is cryptographically tied to the signed component, and no one can swap the image without invalidating the signature.

`make deploy` calls `build`, `sign`, then `deploy.sh` to deploy the application. Consumers can also download the full deployment bundle for self-contained execution.

## Prerequisites

- OCM CLI v2 ≥ 0.17.0
- kind
- `make`
- `shellcheck` (for linting)
- `jq`
- `openssl`
- `kubectl` (for deploying)
- `docker` (for `make e2e` or `make e2e-run` only)
- Docker Hub access for `make build` and `make test` (to resolve `nginx:1.27-alpine`)

OCM CLI and kind are provided by the devcontainer image. Outside the devcontainer, put `ocm` and `kind` on your PATH.

The `.devcontainer/` directory provides all required tools when used with Docker Desktop or a compatible Docker host and devcontainers CLI.

## Lifecycle

```bash
make build           # build the OCM component archive (CTF)
make sign            # sign with an auto-generated dev RSA key
make verify          # verify the signature
make manifests       # download and render app manifests from the component
make deploy          # deploy the application to the current cluster (requires KUBECONFIG)
make cluster-up      # create or reuse the kind cluster; writes build/e2e/kubeconfig (requires docker)
make e2e-run         # run e2e against an existing cluster
make cluster-down    # delete the kind cluster
make e2e             # spin up kind cluster, deploy, verify pod ready, tear down (requires docker)
make publish OCM_REPO=ghcr.io/<you>/ocm  # transfer to an OCI registry
```

## Consuming the component

A consumer who has pulled the component into a local CTF can download the full deployment bundle:

```sh
REF="ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0"

# Verify the component signature before downloading anything
OCM verify cv --config /path/to/verify.ocmconfig "$REF"

# Download scripts and constructor into a bundle directory
mkdir -p bundle/scripts
for s in lib verify manifests deploy; do
  rm -f "bundle/scripts/$s.sh"
  ocm download resource "$REF" --identity name=script-$s \
    --output bundle/scripts/$s.sh
done
rm -f bundle/component-constructor.yaml
ocm download resource "$REF" --identity name=component-constructor \
  --output bundle/component-constructor.yaml
```

Then deploy:

```sh
CTF=./build/ctf BUILD_DIR=/tmp/deploy VERIFY_CONFIG=/path/to/verify.ocmconfig bash bundle/scripts/deploy.sh
```

Notes:
- Downloaded files are mode 0600. Run them with `bash`, not `./`.
- OCM 0.17 appends to an existing `--output` file. Always download into a clean directory.
- `deploy.sh` creates the application but does not tear it down. To delete: `kubectl delete ns hello-world`

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

## Version management

Renovate bumps `OCM_CLI_VERSION` together with both `OCM_SHA256_LINUX_AMD64` and `OCM_SHA256_LINUX_ARM64` in a single PR, using the `github-release-attachments` datasource and `# renovate: ocm-linux-<arch> <version>` marker comments in the Dockerfile.

`KIND_SHA256_*` ARGs are still updated by hand when Renovate bumps `KIND_VERSION`.

## Real signing keys

Dev keys are generated once into `build/keys/` and are gitignored. For production:

```bash
SIGNING_KEY=/path/to/private.pem VERIFY_KEY=/path/to/public.pem make sign verify
```

## Running tests

```bash
make test  # run the test suite
```

Tests include:
- Component structure and resource metadata
- Signature verification with correct and wrong keys
- Manifest rendering with digest-pinned images
- Deploy workflow and error handling
- Script resource download and bundle self-containedness

## CI

CI runs on `ubuntu-latest` (linux/amd64) inside the devcontainer across three workflows:

- **`ci.yaml`** — runs on every push and pull request to `main`: lint and unit tests.
- **`release.yaml`** — triggered by a `v*.*.*` tag or `workflow_dispatch` with a semver `version` input. Runs tests, then builds and signs the OCM component with `OCM_SIGNING_KEY`, uploads a `application-ctf` artifact, and on tags publishes the component to `ghcr.io/<owner>/ocm` and creates a GitHub release.
- **`e2e.yaml`** — runs on every push and pull request to `main`. A `package` job builds and signs the component with an auto-generated dev key and uploads it; a `deploy` job downloads it and verifies the signature and deploys it to a kind cluster.

Required repository secrets: `OCM_SIGNING_KEY` (RSA private key PEM).

## Notes

- `make build` and `make test` require Docker Hub access to resolve `nginx:1.27-alpine`. If Docker Hub is unavailable, builds will fail.
