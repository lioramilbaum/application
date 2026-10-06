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

- OCM CLI v2 ≥ 0.17.0 (`make tools` downloads it into `bin/`)
- `jq`
- `openssl`
- `curl` (for fetching OCM binary)
- `kubectl` (for deploying)
- `docker` (for `make e2e` only; requires macOS 26 Apple Silicon/darwin-arm64)
- darwin/arm64 platform (for `make tools`)
- Docker Hub access for `make build` and `make test` (to resolve `nginx:1.27-alpine`)

## Lifecycle

```bash
make tools           # download OCM CLI and kind binary
make build           # build the OCM component archive (CTF)
make sign            # sign with an auto-generated dev RSA key
make verify          # verify the signature
make manifests       # download and render app manifests from the component
make deploy          # deploy the application to the current cluster (requires KUBECONFIG)
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

## Version management

When Renovate bumps the OCM CLI version in `scripts/fetch-ocm.sh` or the kind version in `scripts/fetch-kind.sh`, the corresponding SHA256 constant (`OCM_CLI_SHA256_DARWIN_ARM64` or `KIND_SHA256_DARWIN_ARM64`) must be manually updated to match the new release. Renovate can only update version numbers; computing and verifying SHA256 checksums requires manual verification against the release artifacts.

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
- Checksum validation for binary downloads

## CI

CI runs on macOS 26 Apple Silicon (darwin/arm64). Lint and test run on every push and pull request. Tests require Docker Hub access to resolve the nginx image.

## Notes

- `make build` and `make test` require Docker Hub access to resolve `nginx:1.27-alpine`. If Docker Hub is unavailable, builds will fail.
- The OCM binary is platform-specific (darwin/arm64 only). To support other platforms, add additional fetch targets to `scripts/fetch-ocm.sh`.