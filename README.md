# application

A minimal HelloWorld application built with the [Open Component Model](https://ocm.software) (OCM v2), deployed on a kind cluster.

## Component tree

```text
github.com/lioramilbaum/application
├── hello-world-image  (ociImage, architecture=amd64, docker.io/library/nginx:1.31-alpine)
├── hello-world-image  (ociImage, architecture=arm64, docker.io/library/nginx:1.31-alpine)
├── hello-world-manifests  (blob, application/yaml, Kubernetes manifests)
├── hello-world-localization  (localizationConfig, application/json, image localization rules)
└── deploy-bundle  (directoryTree, deployment scripts and descriptor)
    ├── component-constructor.yaml  (OCM component descriptor)
    ├── scripts/lib.sh  (shared script functions)
    ├── scripts/verify.sh  (signature verification)
    ├── scripts/manifests.sh  (download and render manifests)
    └── scripts/deploy.sh  (deploy to Kubernetes)

Sources:
└── application-source  (git, GitHub repository with commit SHA)
```

The names in the tree are artifact identities within `github.com/lioramilbaum/application:<version>` — see [Component identity](#component-identity).

## How it works

A single OCM component with 5 direct resources and 1 source (no component references):

- **hello-world-image**: nginx container image (digest-pinned from Docker Hub)
- **hello-world-manifests**: Kubernetes Namespace, ConfigMap, Deployment, and Service manifests
- **hello-world-localization**: signed localization rules (`components/hello-world/localization.json`) mapping each image resource to a container field in the manifests
- **deploy-bundle**: directoryTree containing the deployment scripts and OCM component descriptor
- **application-source**: git source reference with the repository URL and commit SHA

The key concept is **digest-pinned images**. At build time, the OCM component records the nginx image with the digest already pinned in `component-constructor.yaml` (e.g., `docker.io/library/nginx:1.31-alpine@sha256:138af8...`). At deploy time, `manifests.sh` downloads the manifest template and the localization rules from the signed component and checks both against their descriptor digests. It then generates a `kustomization.yaml` with JSON 6902 patches that set the target container's image to the pinned digest, and renders the result with `kubectl kustomize`. The rules say which container in which workload gets which image resource, so the mapping is covered by the signature too. The `HELLO_WORLD_IMAGE` placeholder in the manifest is a sentinel: rendering fails if it survives. This ensures reproducible, tamper-evident deployments: the deployed image is cryptographically tied to the signed component, and no one can swap the image or its target field without invalidating the signature. See [Signing and verification](#signing-and-verification) for what the signature covers.

`make deploy` calls `build`, `sign`, then `deploy.sh` to deploy the application. Consumers can also download the full deployment bundle for self-contained execution.

Air-gapped consumers can point the scripts at a registry instead of a local CTF by setting `OCM_COMPONENT_REPO`. It replaces the `ctf::$CTF` prefix in every component reference:

```bash
# Component previously transferred to a local registry (plain HTTP)
export OCM_COMPONENT_REPO=oci::http://localhost:5001
make verify   # verify the signature against the registry copy
make manifests  # render from the registry copy; image references point at the local registry
```

`manifests.sh` accepts transferred image references (`http://` or `https://` prefix, no digest) and pins them to the digest from the signed descriptor. A mismatched or missing digest fails the render.

## Component identity

[Component identity](https://ocm.software/docs/concepts/component-identity/) names every
component version and every artifact independently of where it is stored. A component version
is an immutable snapshot addressed by `name:version`.

**Component name** follows a DNS-based scheme: a domain the owner controls followed by at least
one path segment. The full regex the OCM CLI enforces is:

```
^[a-z][-a-z0-9]*([.][a-z][-a-z0-9]*)*[.][a-z]{2,}(/[a-z][-a-z0-9_]*([.][a-z][-a-z0-9_]*)*)+$
```

`ocm add cv` rejects `example.com/Demo` (uppercase letter), `demo` (no domain), and `example.com`
(no path segment). This component's name `github.com/lioramilbaum/application` is the GitHub
organization URL where the owner controls the namespace.

**Component version** is relaxed SemVer: the `v` prefix is optional, pre-release and build
metadata are allowed, and `latest` is rejected. `release.yaml` strips the tag's `v` prefix, so
Git tag `v0.1.0` becomes component version `0.1.0`.

**Reference syntax** is `[<type>::]<repository>//<name>[:<version>]`. For this component:

```
ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0
```

The repository (`ctf::./build/ctf`) locates the component but is not part of its identity. That
is why `OCM_COMPONENT_REPO=oci::http://localhost:5001` addresses the same component version and
why transfer preserves signatures. Leaving out `:<version>` lists all versions.

### Artifact identity

Each resource and source has an identity relative to its component version: `name` (required),
`extraIdentity` (an optional string map for variants such as platform splits), and `version`.
Duplicate identities are rejected at build time (`duplicate resource identities`). `type`, `labels`, `relation` and `access` are
not part of identity — two resources that differ only in those still collide.

This component's elements and their identities:

| Element | Identity | Name coordinate |
|---|---|---|
| resource `hello-world-image` (amd64) | `name=hello-world-image,version=0.1.0,architecture=amd64` | `github.com/lioramilbaum/application:0.1.0:resource/hello-world-image` |
| resource `hello-world-image` (arm64) | `name=hello-world-image,version=0.1.0,architecture=arm64` | `github.com/lioramilbaum/application:0.1.0:resource/hello-world-image` |
| resource `hello-world-manifests` | `name=hello-world-manifests,version=0.1.0` | `github.com/lioramilbaum/application:0.1.0:resource/hello-world-manifests` |
| resource `hello-world-localization` | `name=hello-world-localization,version=0.1.0` | `github.com/lioramilbaum/application:0.1.0:resource/hello-world-localization` |
| resource `deploy-bundle` | `name=deploy-bundle,version=0.1.0` | `github.com/lioramilbaum/application:0.1.0:resource/deploy-bundle` |
| source `application-source` | `name=application-source,version=0.1.0` | `github.com/lioramilbaum/application:0.1.0:source/application-source` |

`hello-world-image` ships as two platform variants: `architecture: amd64` and `architecture: arm64`.
Each points to its platform-specific manifest digest of `nginx:1.31-alpine`, keeping the identities
unique while the name stays the same. The name coordinate alone is ambiguous for these variants —
`ocm download resource` would return `got 2`; pass `--identity architecture=amd64` (or `arm64`) to
select one (see [Selecting an artifact](#selecting-an-artifact)). `manifests.sh` selects the variant
matching `TARGET_ARCH` (default: host architecture from `scripts/lib.sh`). The
`application.lioramilbaum.github.com/tier` label is metadata for tools, not identity — see
[Signing and verification](#signing-and-verification) for what labels are signed.

### Selecting an artifact

`ocm download resource` takes `--identity key=value,...` pairs. OCM prefers an exact match, falls
back to a subset match, and requires exactly one candidate:

| `--identity` | Result |
|---|---|
| `name=deploy-bundle` | OK (subset match, one candidate) |
| `name=deploy-bundle,version=0.1.0` | OK (exact match) |
| `version=0.1.0` | error: `expected exactly one resource candidate to download, got 5` |
| `name=deploy-bundle,version=9.9.9` | error: `expected exactly one resource candidate to download, got 0` |
| `name=hello-world-image` | error: `expected exactly one resource candidate to download, got 2` |
| `name=hello-world-image,architecture=amd64` | OK (subset match, one candidate) |

`scripts/manifests.sh` does not pass `--identity` for the image. It selects the `hello-world-image`
resource whose `extraIdentity.architecture` matches `TARGET_ARCH` (default: the host architecture
from `scripts/lib.sh`) and fails unless exactly one candidate matches.

This is distinct from the *consumer identity* in [Credential system](#credential-system), which
identifies the endpoint a credential belongs to.

## Credential system

OCM resolves credentials by consumer identity. Each operation describes the thing it talks to (a signing key, a registry host), and OCM looks up a matching credential in its configuration. See the [OCM credential system](https://ocm.software/docs/concepts/credential-system/) documentation for the full model.

OCM reads configuration from the first source that applies:

- `--config <file>` flags (repeatable; `-` reads from stdin). An explicit `--config` turns off discovery.
- the `OCM_CONFIG` environment variable
- `~/.ocmconfig`
- `~/.config/ocm/config`

| Operation | Consumer identity | Credential type | Config source |
|---|---|---|---|
| `make sign` | `RSA/v1alpha1` + `algorithm` + `signature` | `RSACredentials/v1` (private + public key files) | `build/sign.ocmconfig`, generated by `scripts/keys.sh` |
| `make verify` | same | public key only | `build/verify.ocmconfig`, generated by `scripts/keys.sh` |
| `make publish` (with creds) | `OCIRegistry` + `hostname` [+ `port`] | `OCICredentials/v1` from env vars (never written to disk) | stdin via `--config -`; `DockerConfig/v1` fallback for other registries |
| `make publish` (no creds) | — | — | OCM config discovery (`~/.ocmconfig`, auto Docker setup) |

Resolution order for a lookup:

1. **Direct consumer match**: a consumer whose identity matches the target (for example, `OCIRegistry` with the registry hostname).
2. **Repository fallback**: a `repositories` entry such as `DockerConfig/v1`, which reads `~/.docker/config.json`.

Publishing to a registry with credentials from the environment:

```bash
OCM_REPO=oci://ghcr.io/<you>/ocm \
OCM_REGISTRY_USERNAME=<you> \
OCM_REGISTRY_PASSWORD=<token> \
make publish
```

The token is passed to OCM over stdin and is never written to disk. `OCM_REGISTRY_HOST` overrides the hostname derived from `OCM_REPO` if the registry identity differs from the URL host.

To keep credentials permanently, add the same consumer block to `~/.ocmconfig` under `credentials.config.ocm.software` instead.

Note: `--config -` (stdin) requires OCM CLI ≥ 0.19.1. With an older CLI, put the consumer block in `~/.ocmconfig` and omit the environment variables.

## Resolvers

A component reference does not carry a repository address. The repository on the command line locates the root component only. Resolvers map component name patterns to repositories, so `get cv --recursive`, `transfer cv --recursive`, and `add cv` can find the components that a component references. An explicit repository in a `componentReferences` entry always wins for that component. See the [OCM resolvers](https://ocm.software/docs/concepts/resolvers/) documentation for the full model.

This repository has no `componentReferences`, so its own build scripts never consult a resolver. Resolvers matter to consumers that reference `github.com/lioramilbaum/application`.

A resolver entry takes these fields, under `type: resolvers.config.ocm.software/v1alpha1` nested inside a `generic.config.ocm.software/v1` block:

| Field | Required | Description |
|---|---|---|
| `repository` | yes | OCM repository target (`CommonTransportFormat/v1`, `OCIRepository/v1`, etc.) |
| `componentNamePattern` | no (empty = match all) | Glob. Empty matches everything. |
| `versionConstraint` | no | Semver range (e.g. `>=1.0.0`, `^0.1`) |

Notes:

- `**` matches any depth. The current OCM CLI compiles globs without a path separator, so `*` also crosses `/`. Use `**` when you mean any depth, to be safe.
- Resolvers are tried in order and the first match wins, with no fallback. Put specific or constrained entries before catch-all entries.

Local workflow with a CTF:

```bash
make build resolvers
# build a consumer component that references this one
ocm add cv \
  --repository ctf::./build/consumer-ctf \
  --constructor consumer.yaml \
  --config build/resolvers.ocmconfig \
  --external-component-version-copy-policy skip
# follow the reference recursively
ocm get cv ctf::./build/consumer-ctf//example.com/your-consumer:1.0.0 \
  --recursive --config build/resolvers.ocmconfig -o tree
```

Without `--config build/resolvers.ocmconfig`, both commands fail to resolve the reference.

For a published component, add the resolver to `~/.ocmconfig`:

```yaml
type: generic.config.ocm.software/v1
configurations:
  - type: resolvers.config.ocm.software/v1alpha1
    resolvers:
      - repository:
          type: OCIRepository/v1
          baseUrl: ghcr.io
          subPath: lioramilbaum/ocm
        componentNamePattern: "github.com/lioramilbaum/**"
```

Validation: unknown keys (for example `component:` or `version:`) are silently ignored. Bad globs and invalid semver constraints are rejected only when OCM runs a command that loads resolvers, not by `ocm version`.

## Resource repositories

Each resource in a component descriptor has an [`access:`](https://ocm.software/docs/concepts/resource-repositories/) specification that says where the artifact lives and how to retrieve it. OCM uses that type to route downloads and uploads to the right backend — an OCI registry, a Helm repository, cloud storage, or a [plugin-backed](#plugin-system) store.

### Resources in this component

| Resource | Relation | Access type | Where the bytes live |
|---|---|---|---|
| `hello-world-image` | external | `OCIImage/v1` | Docker Hub — `docker.io/library/nginx:1.31-alpine@sha256:…` |
| `hello-world-manifests` | local | `LocalBlob/v1` | inside the component repository (CTF or OCI layer) |
| `hello-world-localization` | local | `LocalBlob/v1` | inside the component repository |
| `deploy-bundle` | local | `LocalBlob/v1` | inside the component repository |
| `application-source` (source) | — | `GitHub/v1` | GitHub — referenced only, never copied |

**`input:` vs `access:`** in `component-constructor.yaml`: an `input:` block is read at build time and stored as a `LocalBlob/v1` in the component repository. An `access:` block points at an artifact already in an external resource repository; OCM records only the reference and its digest. The nginx image digest is already pinned in `component-constructor.yaml`; OCM records it as-is without re-resolving it from Docker Hub.

Inspect the built descriptor:

```bash
ocm get cv ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0 -o json \
  | jq -r '.[0].component.resources[] | [.name, .relation, .access.type] | @tsv'
```

### Transfer behaviour

`ocm transfer cv` copies the component descriptor and local blobs by default. The `--copy-resources` flag also downloads external resources and re-uploads them to the target:

| Flags | Image after transfer | Air-gap safe? |
|---|---|---|
| *(none)* | still at `docker.io/library/nginx:1.31-alpine@sha256:…` (`OCIImage/v1`) | no |
| `--copy-resources` | inlined as `LocalBlob/v1` in the component layer | yes (carry the archive) |
| `--copy-resources --upload-as ociArtifact` | pushed as its own artifact (`ociArtifact/v1`), pullable by kubelet | yes (push to registry) |

`make publish` uses `--copy-resources --upload-as ociArtifact` so the published component doesn't depend on Docker Hub and the image remains pullable.

Sources (`GitHub/v1`) are never copied by any transfer mode.

The signature covers resource digests, not access specs, so `make verify` still passes after transfer — the digest is unchanged even when the image moves to a new registry. See [Signing and verification](#signing-and-verification) for the full list of signed and unsigned fields.

`--copy-resources` reads from Docker Hub, so source-side registry credentials come from the `DockerConfig/v1` fallback described in [Credential system](#credential-system).

Preview a transfer plan without running it:

```bash
REF="ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0"
ocm transfer cv "$REF" oci::http://localhost:5001 \
  --copy-resources --upload-as ociArtifact --dry-run -o yaml
```

## Canonical component repositories

A [canonical repository](https://ocm.software/docs/concepts/canonical-component-repositories/)
holds every component of a component graph, so `get cv --recursive` and `transfer cv --recursive`
need no resolvers. This component has no references, so any repository that holds it is canonical.

`make build` always writes it to `build/ctf/` in the
[Common Transport Format](https://ocm.software/docs/concepts/transfer-and-transport/) (CTF),
a filesystem OCM repository of OCI-compatible content:

```text
build/ctf/
├── artifact-index.json   # maps component-descriptors/<name>:<version> to a manifest digest
└── blobs/                # content-addressed files (sha256.<hex>): manifests, descriptor, resources
```

A CTF is self-contained: every blob its manifests reference is in `blobs/`, so it works as a
directory or a tar archive (`ctf::application.ctf.tar`) on any host, including offline. External
resources (the nginx image) stay as references unless transferred with `--copy-resources`.
Sign before the CTF leaves the build host — the signature travels inside the descriptor, so
`CTF=application.ctf.tar make verify` passes on any copy.

An OCI registry (`oci::`) stores the same manifests and blobs behind a network API for online
consumers. `make publish` transfers the CTF to a registry (`ctf::build/ctf` → `oci::<registry>`).

## Kubernetes controller

The [OCM controllers](https://ocm.software/docs/concepts/kubernetes-controllers/) are a
Kubernetes operator that manages component versions declaratively. A `Repository` custom
resource points at an OCM registry and a `Component` custom resource names a component
and a semver constraint; the controller resolves and verifies the highest matching version,
records it in `status.component`, and re-checks every `interval`. This inverts `make deploy`:
instead of scripts pushing into the cluster, the cluster pulls new releases from the registry
(GitOps style). Minimal CRs for the component `release.yaml` publishes:

```yaml
apiVersion: delivery.ocm.software/v1alpha1
kind: Repository
metadata: {name: application-repository}
spec:
  repositorySpec:
    type: OCIRegistry
    baseUrl: ghcr.io/lioramilbaum/ocm
  interval: 10m
---
apiVersion: delivery.ocm.software/v1alpha1
kind: Component
metadata: {name: application}
spec:
  component: github.com/lioramilbaum/application
  repositoryRef: {name: application-repository}
  semver: ">=0.1.0"
  interval: 10m
```

This repository installs no controller or CRDs; the source is
[`bindings/go/kubernetes/controller`](https://github.com/open-component-model/open-component-model/tree/main/bindings/go/kubernetes/controller).
[Kubernetes deployer](#kubernetes-deployer) shows how to apply the manifests from the cluster.

## Kubernetes deployer

The [deployer](https://ocm.software/docs/concepts/kubernetes-deployer/) ends the controller
chain above: a `Resource` picks one resource of the `Component`, and once it is ready a
`NamespacedDeployer` server-side applies its manifests impersonating the service account named by `spec.serviceAccountName`, then
prunes and reverts drift with ApplySets. `deploy.sh` instead runs a one-shot `kubectl apply`
with the caller's credentials; here the cluster holds the desired state. The deprecated
cluster-scoped `Deployer` uses the controller's own permissions.

```yaml
apiVersion: delivery.ocm.software/v1alpha1
kind: Resource
metadata: {name: hello-world-manifests}
spec:
  componentRef: {name: application}
  resource: {byReference: {resource: {name: hello-world-manifests}}}
---
apiVersion: delivery.ocm.software/v1alpha1
kind: NamespacedDeployer
metadata: {name: hello-world}
spec: {resourceRef: {name: hello-world-manifests}, serviceAccountName: hello-world-deployer}
```

The manifests create the `hello-world` Namespace, so `hello-world-deployer` needs a `ClusterRole`.
The deployer applies the blob as-is and skips `manifests.sh` localization: `HELLO_WORLD_IMAGE`
reaches the cluster unpatched, and the controller has no `Localization` CR to fill it in
([how-to](https://ocm.software/docs/how-to/deploy-manifests-with-deployer/),
[source](https://github.com/open-component-model/open-component-model/tree/main/bindings/go/kubernetes/controller/internal/controller/deployer)).

## Plugin system

The [OCM plugin system](https://ocm.software/docs/concepts/plugin-system/) adds repository
types, access types, input types, credential backends, and signing handlers to OCM without
forking it. A plugin is a standalone binary, usually built with the Go SDK in
[`bindings/go/plugin`](https://github.com/open-component-model/open-component-model/tree/main/bindings/go/plugin).
The `ocm` CLI scans one directory, `--plugin-directory` (default `$HOME/.config/ocm/plugins`),
runs each binary with `capabilities` to learn which types it serves, and starts it only when a
command needs one of them. Requests are HTTP + JSON over a Unix domain socket (or TCP in scratch containers), and the
plugin exits after an idle timeout. Plugin settings go in `.ocmconfig` under the plugin's own `type`.

Every type this component uses is served by a built-in plugin compiled into `ocm`, so build,
sign, verify, and transfer need no plugin installed:

| Type in this component | Built-in plugin |
|---|---|
| `CommonTransportFormat/v1` (`ctf::`), `OCIRepository/v1` (`oci::`), `OCIImage/v1`, `LocalBlob/v1` | OCI |
| `file` and `Dir/v1` inputs | file, dir |
| `GitHub/v1` source access | GitHub |
| `RSA/v1alpha1` signatures | RSA |

An external plugin fits when an artifact lives where OCM cannot reach it. If the manifests sat
in an internal artifact store, a resource repository plugin for that store's access type would
let `component-constructor.yaml` reference them with `access:` while `make build`,
`ocm download resource`, and `make publish` stay unchanged. Plugins are shipped as OCM
component versions, so `ocm download plugin` fetches a plugin binary from one into the plugin
directory.

## Signing and verification

The [OCM signing and verification](https://ocm.software/docs/concepts/signing-and-verification/)
model signs the component descriptor, not the artifact bytes directly. `ocm sign cv` normalizes
the descriptor with `jsonNormalisation/v4alpha1` (JSON canonicalization after dropping excluded
fields), hashes the result with `SHA-256`, and signs the hash with `RSASSA-PSS`. The signature
is stored in the descriptor's `signatures` list under the name `default` (or `sigstore` for
keyless signing). `ocm verify cv` recomputes the digest from the normalized descriptor and
checks it against the stored signature using the public key from `build/verify.ocmconfig`. It
does not download resources. Content integrity at deploy time is enforced separately by
`manifests.sh`, which rejects any image reference whose digest differs from the one recorded in
the component descriptor.

Inspect the signature of the built component:

```bash
ocm get cv ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0 -o json \
  | jq '.[0].signatures[0]'
```

Each resource has a `genericBlobDigest/v1` digest that the signature binds. The signature
covers only the fields that survive normalization:

### What the signature covers

| Field | Signed? | Effect of changing it after signing |
|---|---|---|
| `component.name`, `version`, `provider` | yes | `make verify` fails with `digest mismatch` |
| Resource `name`, `version`, `type`, `relation`, `digest` | yes | `make verify` fails with `digest mismatch` |
| Source `name`, `version`, `type` | yes | `make verify` fails with `digest mismatch` |
| Label with `signing: true` | yes | `make verify` fails with `digest mismatch` |
| Label **without** `signing: true` | **no** | `make verify` still passes |
| Resource and source `access` | **no** | `make verify` still passes |
| `component.repositoryContexts` | **no** | `make verify` still passes (enables transfer) |
| `srcRefs` | **no** | `make verify` still passes |
| `signatures` | **no** | not part of what is signed |

Three consequences for this component:

- `application.lioramilbaum.github.com/tier` has no `signing: true`. Anyone who can write to
  the repository can change its value and `make verify` still passes. Do not base trust
  decisions on unsigned labels. To protect a label, add `signing: true` to it before signing.
- The `application-source` commit SHA lives in the source's `access`, so it is not signed.
  The source entry (name, version, type) is signed; the commit reference is not.
- The image `access.imageReference` is not signed, which is why transfer can rewrite
  references without breaking signatures. The image's `digest` is signed, and `manifests.sh`
  enforces it at deploy time.

### Trust models

| Model | What the verifier trusts | Config in this repo |
|---|---|---|
| Key pinning (plain encoding) | The public key file you provide | `RSA/v1alpha1` consumer in `build/verify.ocmconfig` |
| Certificate chain (PEM encoding, early access) | A certificate chain from a trusted CA | `signatureEncodingPolicy` in `RSASigningConfiguration` |
| Identity-based (Sigstore keyless) | A Fulcio certificate matching issuer and identity regexp | `SigstoreVerificationConfiguration/v1alpha1` in `build/verify-sigstore.ocmconfig` |

Key pinning is the simplest: rotate the key by deleting the existing key files and re-running
`scripts/keys.sh`, then re-signing. Sigstore keyless signing records the certificate in a Rekor transparency log, so
verification does not require a long-lived key: `SIGNING_METHOD=sigstore make sign` uses the
OIDC token from the CI environment.

## Prerequisites

- OCM CLI v2 ≥ 0.17.0 (publishing with `OCM_REGISTRY_USERNAME`/`OCM_REGISTRY_PASSWORD` requires ≥ 0.19.1)
- kind
- `make`
- `shellcheck` (for linting)
- `jq`
- `openssl`
- `kubectl` (for deploying and for `make manifests`, which uses `kubectl kustomize`)
- `docker` (for `make e2e` or `make e2e-run` only)
- Docker Hub access for `make build` and `make test` (to resolve `nginx:1.31-alpine`)

OCM CLI and kind are provided by the devcontainer image. Outside the devcontainer, put `ocm` and `kind` on your PATH.

The `.devcontainer/` directory provides all required tools when used with Docker Desktop or a compatible Docker host and devcontainers CLI.

## Lifecycle

```bash
make build           # build the OCM component archive (CTF)
make sign            # sign with an auto-generated dev RSA key
make verify          # verify the signature
make resolvers       # write build/resolvers.ocmconfig mapping github.com/lioramilbaum/** to the local CTF
make manifests       # download and render app manifests from the component
make deploy          # deploy the application to the current cluster (requires KUBECONFIG)
make cluster-up      # create or reuse the kind cluster; writes build/e2e/kubeconfig (requires docker)
make e2e-run         # run e2e against an existing cluster
make cluster-down    # delete the kind cluster
make e2e             # spin up kind cluster, deploy, verify pod ready, tear down (requires docker)
make publish OCM_REPO=ghcr.io/<you>/ocm  # transfer to an OCI registry, copying external resources (e.g. the nginx image) as OCI artifacts; optional OCM_REGISTRY_USERNAME/OCM_REGISTRY_PASSWORD
```

## Consuming the component

A consumer who has pulled the component into a local CTF can download the full deployment bundle:

```sh
REF="ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0"

# Verify the component signature before downloading anything
OCM verify cv --config /path/to/verify.ocmconfig "$REF"

# Download deploy-bundle into a fresh directory
rm -rf bundle
mkdir -p bundle
ocm download resource "$REF" --identity name=deploy-bundle \
  --output bundle/
```

Then deploy:

```sh
CTF=./build/ctf BUILD_DIR=/tmp/deploy VERIFY_CONFIG=/path/to/verify.ocmconfig bash bundle/scripts/deploy.sh
```

Notes:

- Downloaded files are mode 0600. Run them with `bash`, not `./`.
- The deploy-bundle is a tar.gz archive that is automatically extracted by `ocm download resource`.
- `deploy.sh` creates the application but does not tear it down. To delete: `kubectl delete ns hello-world`
- `--identity name=deploy-bundle` selects the resource by artifact identity (subset match — only one resource has that name); see [Component identity](#component-identity).

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

## Source provenance

The component includes a source reference (`application-source`) with:

- **Repository URL**: the GitHub repository
- **Commit SHA**: the exact git commit used to build the component

The commit SHA is recorded in the source's `access` field, which is excluded from normalization and therefore not signed — see [Signing and verification](#signing-and-verification).

The commit SHA is determined by:

1. `SOURCE_COMMIT` environment variable, if set
2. Otherwise, the current HEAD of the git repository (via `git rev-parse HEAD`)

Note: SOURCE_COMMIT must be a 40-character hex string (a full git commit SHA). A dirty working tree is not reflected in the source reference — only the commit SHA matters.

## Keyless signing (Sigstore)

To sign with Sigstore/Cosign keyless signing (requires OIDC token):

```bash
SIGNING_METHOD=sigstore make build sign verify
```

Signature names:

- `default`: RSA signature (default behavior)
- `sigstore`: Sigstore keyless signature (when `SIGNING_METHOD=sigstore`)

For local testing with Sigstore:

```bash
export SIGSTORE_ID_TOKEN="<your-oidc-token>"
SIGNING_METHOD=sigstore make sign verify
```

In GitHub Actions, add `id-token: write` to the job's `permissions:` block. The CI/CD will use GitHub's OIDC provider to acquire a token automatically.

**Note on certificate validation**: OCM does not currently honour the `tokenFile` configuration option; use `SIGSTORE_ID_TOKEN` environment variable instead.

## Running tests

```bash
make test  # run the test suite
```

Tests include:
- Component structure and resource metadata
- Signature verification with correct and wrong keys
- Manifest rendering with digest-pinned images
- Localization rules: resource metadata (`localization resource metadata`), rule-based image injection (`manifests localizes by rule not placeholder`), rejection of untargeted rules (`manifests rejects untargeted localization`), wrong container (`manifests rejects wrong container`), and tampered rules (`manifests rejects tampered localization`)
- Deploy workflow and error handling
- Script resource download and bundle self-containedness
- Component reference override: `cv_ref honours OCM_COMPONENT_REPO`, `manifests reads from OCM_COMPONENT_REPO`
- Transferred images: `manifests localizes transferred image`, `manifests rejects mismatched image digest`, `manifests rejects missing image digest`
- Local registry mirror for kind nodes: `cluster.sh configures local registry mirror`
- CI e2e isolation: `e2e workflow isolates deploy`
- Resource access types: `resource access types`, `readme documents resource access types`
- Publish copies resources: `publish copies resources as OCI artifacts`
- Transfer plans: `transfer without copy-resources keeps external reference`, `transfer copy-resources inlines image as local blob`, `transfer copy-resources uploads OCI artifact`
- Canonical component repositories (CTF): `ctf layout is canonical`, `ctf archive is portable and signed`, `readme documents canonical component repositories`
- Kubernetes controller: `readme documents kubernetes controller`
- Kubernetes deployer: `readme documents kubernetes deployer`
- Plugin system: `builtin plugins serve component types`, `readme documents plugin system`
- Signing and verification: `signature covers normalized descriptor`, `readme documents signing and verification`
- Component identity: `component identity selects artifacts`, `component identity rules enforced`, `readme documents component identity`

## CI

CI runs on `ubuntu-latest` (linux/amd64) inside the devcontainer across three workflows:

- **`ci.yaml`** — runs on every push and pull request to `main`: lint and unit tests.
- **`release.yaml`** — triggered by a `v*.*.*` tag or `workflow_dispatch` with a semver `version` input. Runs tests, then builds and signs the OCM component with `OCM_SIGNING_KEY`, uploads a `application-ctf` artifact, and on tags publishes the component to `ghcr.io/<owner>/ocm` and creates a GitHub release.
- **`e2e.yaml`** — runs on every push and pull request to `main`. A `package` job builds and signs the component with an auto-generated dev key and uploads it. A `deploy` job downloads it, verifies the signature, and runs the e2e in isolation: it creates the kind cluster and pre-pulls the rendered manifest images into the kind nodes, then blocks new outbound connections from the kind network with an iptables `DOCKER-USER` rule and starts a `tcpdump` capture on the kind bridge. It runs `make e2e-run` against the cluster, then removes the rule, stops the capture, and fails if any packet left the private ranges for the public internet. The pcap and tcpdump text are uploaded as the `application-e2e-egress-evidence` artifact.

Required repository secrets: `OCM_SIGNING_KEY` (RSA private key PEM).

## Notes

- `make build` and `make test` require Docker Hub access to resolve `nginx:1.31-alpine`. If Docker Hub is unavailable, builds will fail.
