# application

A minimal HelloWorld application built with the [Open Component Model](https://ocm.software) (OCM v2), deployed on a kind cluster.

## Component tree

```text
github.com/lioramilbaum/application
├── hello-world-image  (ociImage, architecture=amd64, docker.io/library/nginx:1.31-alpine)
├── hello-world-image  (ociImage, architecture=arm64, docker.io/library/nginx:1.31-alpine)
├── hello-world-manifests  (blob, application/yaml, Kubernetes manifests)
├── hello-world-localization  (localizationConfig, application/json, image localization rules)
├── hello-world-config  (configData, application/json, deploy-time configuration values)
├── hello-world-sbom  (sbom, application/vnd.cyclonedx+json)
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

A single OCM component with 7 direct resources and 1 source (no component references):

- **hello-world-image**: nginx container image (digest-pinned from Docker Hub)
- **hello-world-manifests**: Kubernetes Namespace, ConfigMap, Deployment, and Service manifests
- **hello-world-localization**: signed localization rules (`components/hello-world/localization.json`) mapping each image resource to a container field in the manifests
- **hello-world-config**: signed deploy-time configuration values (`components/hello-world/config.json`) for the replica count and the served `index.html`
- **hello-world-sbom**: CycloneDX 1.6 software bill of materials generated from the constructor (see [Software Bills of Materials](#software-bills-of-materials))
- **deploy-bundle**: directoryTree containing the deployment scripts and OCM component descriptor
- **application-source**: git source reference with the repository URL and commit SHA

The key concept is **digest-pinned images**. At build time, the OCM component records the nginx image with the digest already pinned in `component-constructor.yaml` (e.g., `docker.io/library/nginx:1.31-alpine@sha256:138af8...`). At deploy time, `manifests.sh` downloads the manifest template and the localization rules from the signed component and checks both against their descriptor digests. It then generates a `kustomization.yaml` with JSON 6902 patches that set the target container's image to the pinned digest, and renders the result with `kubectl kustomize`. The rules say which container in which workload gets which image resource, so the mapping is covered by the signature too. The `HELLO_WORLD_IMAGE` placeholder in the manifest is a sentinel: rendering fails if it survives. This ensures reproducible, tamper-evident deployments: the deployed image is cryptographically tied to the signed component, and no one can swap the image or its target field without invalidating the signature. See [Signing and verification](#signing-and-verification) for what the signature covers.

### Deploy-time configuration

The `hello-world-config` resource (`components/hello-world/config.json`, `configData`) carries the values that the manifests take at deploy time. Its schema is `config.application.lioramilbaum.github.com/v1alpha1`, kind `ConfigData`, with a `configurations` array. Each entry has:

- `name`: a label for the entry
- `target`: the `kind` and `name` of the object to patch (for example `Deployment/hello-world`)
- `path`: the JSON pointer of the field to set (for example `/spec/replicas`)
- `placeholder`: the sentinel string that the manifest carries at that field (for example `HELLO_WORLD_REPLICAS`)
- `value`: the signed value to write in place of the placeholder

`components/hello-world/manifests.yaml` contains the placeholders, each annotated with a comment pointing back to the config file. `manifests.sh` downloads the config, checks its sha256 against the descriptor digest, and validates the schema. For each entry it generates a JSON 6902 patch that tests the placeholder and then replaces it with `value`. Rendering fails if any `HELLO_WORLD_*` placeholder survives, so a config entry that does not match its target leaves the placeholder behind and the render stops. Because the values are part of the signed component, changing the replica count or the served page requires rebuilding and re-signing the component.

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
| resource `hello-world-config` | `name=hello-world-config,version=0.1.0` | `github.com/lioramilbaum/application:0.1.0:resource/hello-world-config` |
| resource `hello-world-sbom` | `name=hello-world-sbom,version=0.1.0` | `github.com/lioramilbaum/application:0.1.0:resource/hello-world-sbom` |
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
| `version=0.1.0` | error: `expected exactly one resource candidate to download, got 7` |
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

The application component itself has no `componentReferences`. `scripts/product.sh` uses `build/resolvers.ocmconfig` to resolve the application when building the product component — see [Component References](#component-references). Resolvers also matter to consumers that reference `github.com/lioramilbaum/application`.

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
| `hello-world-sbom` | local | `LocalBlob/v1` | inside the component repository |
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

See [Transfer and transport](#transfer-and-transport) for the dry-run → review → replay workflow.

## Canonical component repositories

A [canonical repository](https://ocm.software/docs/concepts/canonical-component-repositories/)
holds every component of a component graph, so `get cv --recursive` and `transfer cv --recursive`
need no resolvers. This component has no references, so any repository that holds it is canonical. The product component in `build/product-ctf/` is not canonical; `ocm transfer cv --recursive` into a fresh repository makes both components canonical — see [Component References](#component-references).

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

## Transfer and transport

OCM moves component versions between repositories with `ocm transfer cv`. The operation
preserves signatures, resolves local blobs, and optionally recurses into referenced
components. This makes it the standard way to carry a release from a CI build cache into
a production registry, or across an air gap.

See the [OCM transfer and transport concept](https://ocm.software/docs/concepts/transfer-and-transport/)
for the full model.

### What gets transferred

| Item | Transferred | Notes |
|---|---|---|
| Component descriptor | Always | Carries identity, labels, signatures |
| Local blobs | Always | Inlined resources, re-uploaded at target |
| External resources (OCI images) | When selected by an uploader | See [Resource repositories](#resource-repositories) |
| Sources | Never | References only; content stays in origin VCS |
| Referenced components | With `--recursive` | See [Resolvers](#resolvers) |

Signatures travel inside the descriptor. Because OCM verification uses the normalised
descriptor (not the raw bytes), re-uploading resources or rewriting their access does not
invalidate the signature. See [Signing and verification](#signing-and-verification).

### Plan, review, run

Separate the decision from the execution: generate the transfer graph with `--dry-run`,
review it, then replay the exact same graph with `--transfer-spec` (`make publish` sets this from `TRANSFER_SPEC`):

```sh
# 1. Dry-run to localhost:5001 — writes build/transfer-plan.json and prints a summary
make transfer-plan OCM_REPO=oci::http://localhost:5001

# 2. Inspect the plan
jq '.transformations[] | {type, label}' build/transfer-plan.json

# 3. Replay the plan — same graph, same target
make publish OCM_REPO=oci::http://localhost:5001 TRANSFER_SPEC=build/transfer-plan.json
```

The plan is a `TransformationGraphDefinition` JSON document. Each entry has a `type`
(for example `TransferOCIArtifact/v1alpha1`, `OCIAddLocalResource/v1alpha1`,
`OCIAddComponentVersion/v1alpha1`, `CTFGetLocalResource/v1alpha1`) and a `label`. The plan
is a routing graph — OCM reads the actual component descriptor from the source CTF during
replay, not from the plan JSON. Signature protection is enforced on the target CTF or
registry; `make verify` on the target will report `digest mismatch` if the component was
tampered in transit.

There is no separate plan subcommand; the plan is the output of `--dry-run -o json`.

### Uploader configs

An uploader config selects resources and controls where they land:

| Type | Selects | Use case |
|---|---|---|
| `oci.uploader.transfer.config.ocm.software/v1alpha1` | OCI images, Helm charts, OCI-manifest local blobs | Route images to a specific registry path |
| `localblob.uploader.transfer.config.ocm.software/v1alpha1` | Any local blob | Keep arbitrary blobs as local blobs at target |
| `reference.uploader.transfer.config.ocm.software/v1alpha1` | Any resource | Keep resource by reference (no upload) |

The first matching config wins. The deprecated `--copy-resources` and `--upload-as` flags
append entries after any configured ones, so explicit configs always take priority.
Uploader configs require OCM ≥ 0.19.0; earlier versions load the config file without error but silently skip the uploader entries — the transfer proceeds without per-architecture routing.

This repository ships `transfer.ocmconfig`, which routes the two `hello-world-image`
architecture variants to distinct tags by suffixing the tag with `resource.extraIdentity.architecture`. Without it, both variants push to the same
`nginx:1.31-alpine` tag (last write wins):

```sh
make transfer-plan OCM_REPO=oci::http://localhost:5001 TRANSFER_CONFIG=transfer.ocmconfig
make publish OCM_REPO=oci::http://localhost:5001 TRANSFER_SPEC=build/transfer-plan.json
# produces: .../library/nginx:1.31-alpine-amd64 and .../library/nginx:1.31-alpine-arm64
```

### Consumer side

After transfer, point consumers at the target with `OCM_COMPONENT_REPO`. See
[Consuming the component](#consuming-the-component).

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

## Kubernetes component discovery

The [component discovery](https://ocm.software/docs/concepts/kubernetes-component-discovery/)
controller is implemented in
[`bindings/go/kubernetes/controller`](https://github.com/open-component-model/open-component-model/tree/main/bindings/go/kubernetes/controller/internal/controller/discovery).
A `Discovery` references a same-namespace `Component` through `spec.componentRef.name`. Once that
`Component` is `Ready`, the controller resolves its entire transitive reference graph and filters
it with `resourceSelector`, `componentSelector` and `referenceSelector`. Each selector takes
`matchIdentity`, `matchLabels` or `expression` clauses. The matches are then either projected into
`status.extracted` through `extract.byResources`, or left as raw descriptors in `status.components`.

`Component` polls for new versions (semver constraints plus `interval`). `Discovery` has no interval
of its own; it re-runs when the resolved version changes. It is the in-cluster equivalent of the
`jq` resource selection in [`manifests.sh`](#kubernetes-deployer).

Discovery is read-only. It downloads nothing and gives no signature guarantee. Selecting by the
unsigned `tier` label is fine for queries but not for trust decisions; see
[Signing and verification](#signing-and-verification).

The application component has no `componentReferences`, so its graph is just the root and
`referenceSelector` has nothing to match here. A `Component` that tracks
`github.com/lioramilbaum/product` would have `application` in its reference graph, which is what
`referenceSelector` applies to; see [Component References](#component-references) and
[Resolvers](#resolvers).

```yaml
# Requires OCM controller >= v0.15.0 and the Component "application"
# from README "Kubernetes controller" in the same namespace.
apiVersion: delivery.ocm.software/v1alpha1
kind: Discovery
metadata:
  name: hello-world-images
spec:
  componentRef:
    name: application
  componentSelector:
    matchLabels:
      application.lioramilbaum.github.com/tier: application
  resourceSelector:
    matchIdentity:
      name: hello-world-image
  extract:
    byResources:
      architecture: resource.extraIdentity.architecture
      image: resource.access.imageReference
      digest: resource.digest.value
```

The expected result is two records, one per `architecture: amd64` and `architecture: arm64`. After
`make publish`, `image` is the ghcr.io copy without `@sha256`. `digest` is `resource.digest.value`;
it survives transfer unchanged, so pin by it.

A typo in a `byResources` path silently drops that field, and the controller reports no error.
`make test` guards against this by checking every path against the built descriptor.

`Discovery` requires OCM controller v0.15.0 or later.

Only consume the result when `Ready` is `True` and `status.observedGeneration` equals
`metadata.generation`:

```
kubectl get discovery hello-world-images -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
kubectl get discovery hello-world-images -o jsonpath='{.status.extracted}'
```

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
| Component reference (`name`, `componentName`, `version`, `digest`) | yes | `make verify` fails with `digest mismatch` |
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

## Ownership

A descriptor points at its resources, but nothing points back. A resource in a registry is
indistinguishable from any other OCI artifact with the same digest, so nothing in the registry says
which component owns it. OCM can record that owner. See the
[ownership concept](https://ocm.software/docs/concepts/ownership/) and the
[how-to](https://ocm.software/docs/how-to/add-and-verify-ownership/).

### The mechanism

Set `options.ownershipPolicy: Always` on a resource. The default is `Never`. The policy is a
construction-time directive: it is not persisted in the component descriptor, so it is not signed and
does not appear in `ocm get cv`. When OCM constructs the component, it writes a separate OCI referrer
manifest for each opted-in resource that is an OCI manifest:

- `artifactType: application/vnd.ocm.software.ownership.v1+json`
- `subject` is the resource manifest. `subject.digest` equals the resource's `access.localReference`
  (`sha256:` plus the resource `digest.value`).
- An empty config and an empty layer.
- Three annotations:
  - `software.ocm.component.name`: the owning component, for example `github.com/lioramilbaum/ownership-demo`
  - `software.ocm.component.version`: the owning component version
  - `software.ocm.artifact`: a JSON string, for example `{"identity":{"name":"hello-world-site","version":"0.1.0"},"kind":"resource"}`

The record is idempotent. Re-running construction converges to one record per resource.

### Where the record lives

- In a registry, the record is a referrer of the resource manifest, found through the Referrers API.
- In a CTF, the referrers index is stored under the tag `sha256-<hex>` in `artifact-index.json`, where
  `<hex>` is the digest of the resource manifest.

### Which resources get a record

| Resource | Policy | Record | Reason |
|---|---|---|---|
| `hello-world-image` | not set | none | Pushing a referrer to `docker.io/library/nginx` requires write access. Opting in without it fails with `401`. |
| `hello-world-manifests`, `hello-world-localization`, `hello-world-config`, `hello-world-sbom`, `deploy-bundle` | not set | none | Raw blobs (non-manifest media types) are silently skipped, even with `Always`. |
| `hello-world-site` (ownership-demo) | `Always` | yes | OCI manifest, stored locally. |
| `hello-world-site-untracked` (ownership-demo) | `Never` (default) | none | Not opted in. |
| `hello-world-manifests` (ownership-demo) | `Always` | none | Raw blob, silently skipped. |

### Constructor

The ownership demo lives in `components/ownership/`. Its constructor is:

```yaml
# Demonstrates three ownership outcomes side by side:
#   hello-world-site         ownershipPolicy: Always  → 1 ownership record
#   hello-world-site-untracked  (default Never)       → no record
#   hello-world-manifests    ownershipPolicy: Always  → no record (raw blob, silently skipped)
name: github.com/lioramilbaum/ownership-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: hello-world-site
    type: ociArtifact
    version: ${VERSION}
    options:
      ownershipPolicy: Always
    input:
      type: file
      path: ${OWNERSHIP_INPUT_DIR}/hello-world-site.oci.tar.gz
      mediaType: application/vnd.ocm.software.oci.layout.v1+tar+gzip
  - name: hello-world-site-untracked
    type: ociArtifact
    version: ${VERSION}
    input:
      type: file
      path: ${OWNERSHIP_INPUT_DIR}/hello-world-site-untracked.oci.tar.gz
      mediaType: application/vnd.ocm.software.oci.layout.v1+tar+gzip
  - name: hello-world-manifests
    type: blob
    version: ${VERSION}
    options:
      ownershipPolicy: Always
    input:
      type: file
      path: ${ROOT}/components/hello-world/manifests.yaml
      mediaType: application/yaml
```

### Trace the owner

```bash
make ownership
```

`make ownership` builds the demo component into `build/ownership-ctf` and prints the owner of each
resource:

```text
hello-world-site	github.com/lioramilbaum/ownership-demo:0.1.0	{"identity":{"name":"hello-world-site","version":"0.1.0"},"kind":"resource"}
hello-world-site-untracked	-	no ownership record
hello-world-manifests	-	no ownership record (not an OCI manifest)
```

In a registry, query the referrers for the resource image instead:

```bash
oras discover "$IMAGE_REF" --artifact-type application/vnd.ocm.software.ownership.v1+json --format json | jq '.referrers[0].annotations'
```

### Trust

The record is not signed. Before relying on it, confirm that `subject.digest` matches the `digest` of
the resource in a component version you have verified. See [Signing and verification](#signing-and-verification).

### Transfer

A by-value record travels with its subject, so a transfer that copies the resource also copies its
ownership record. See [Transfer and transport](#transfer-and-transport).

## Software Bills of Materials

A **Software Bill of Materials (SBOM)** is an inventory of software components and their relationships. OCM treats an SBOM as a first-class resource of `type: sbom`. When the SBOM resource carries an `ocm.software/artifact-references` label with `signing: true`, it is:

- **Identified** — bound to the resources it describes by name (and extra identity where needed)
- **Signed** — any tampering with the label fails `ocm verify`
- **Travels with the component** — the SBOM is a local blob and moves on every `ocm transfer`

See: [OCM SBOM concept](https://ocm.software/docs/concepts/sboms/) · [Working with SBOMs tutorial](https://ocm.software/docs/tutorials/working-with-sboms/)

> **Note:** `ocm get resource` is an OCM v1 command. OCM v2 uses `ocm get cv -o json | jq` to inspect resources and `ocm download resource [--sbom]` to retrieve them.

### SBOM resource definition

This application ships a CycloneDX 1.6 SBOM covering both nginx image variants and the three delivery files:

```yaml
- name: hello-world-sbom
  type: sbom
  labels:
    - name: ocm.software/artifact-references
      signing: true
      value:
        - identity: {name: hello-world-image, architecture: amd64}
        - identity: {name: hello-world-image, architecture: arm64}
        - identity: {name: hello-world-manifests}
        - identity: {name: hello-world-localization}
        - identity: {name: hello-world-config}
  input:
    type: file
    path: ./build/sbom/hello-world.cdx.json
    mediaType: application/vnd.cyclonedx+json
```

### Generation

`scripts/sbom.sh` generates a deterministic CycloneDX 1.6 document using only `bash`, `jq`, and `awk`. It parses `component-constructor.yaml` as the single source of truth — image digests and file paths — so the SBOM stays current whenever Renovate bumps a digest or a file changes.

The output is written to `build/sbom/hello-world.cdx.json` (under the repo root, not `$BUILD_DIR`, because `File/v1` inputs are confined to the constructor directory). It contains no `timestamp` or `serialNumber`, so the same inputs always produce the same digest.

```sh
make build    # SBOM is regenerated automatically
make sbom     # regenerate only the SBOM
```

### Accessing the SBOM

```sh
# Inspect the SBOM resource in the CTF
ocm get cv ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0 -o json \
  | jq '.[0].component.resources[] | select(.type=="sbom")'

# Download the SBOM directly
ocm download resource ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0 \
  --identity name=hello-world-sbom --output hello-world.cdx.json

# Download the SBOM for a specific resource via --sbom discovery
ocm download resource ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0 \
  --identity name=hello-world-manifests --sbom --output sboms/manifests
ocm download resource ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0 \
  --identity name=hello-world-image,architecture=amd64 --sbom --output sboms/image-amd64
```

### Limitations

- The SBOM is **inventory-level**: it lists deliverables (nginx images by digest and purl, config/manifest files by SHA-256). It does not enumerate Alpine packages inside nginx — that requires `syft`, which is not in the devcontainer.
- `--sbom` discovery is experimental in OCM.
- The pinned per-platform image references are single-architecture manifests, not image indexes; BuildKit attestation discovery does not apply.

Related: [Signing and verification](#signing-and-verification) · [Transfer and transport](#transfer-and-transport)

## Component References

A **component reference** (`componentReferences`) declares that one component version depends on another by name, version, and digest. OCM calls the set of a product's component versions its [Software Bill of Delivery](https://ocm.software/docs/how-to/model-products/).

This repository adds `github.com/lioramilbaum/product` — a product component that references the `github.com/lioramilbaum/application` component:

```yaml
name: github.com/lioramilbaum/product
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
componentReferences:
  - name: application
    componentName: github.com/lioramilbaum/application
    version: ${VERSION}
```

When `ocm add cv` builds the product, it resolves the reference and computes a `digest` from the application's normalized descriptor (`jsonNormalisation/v4alpha1`, SHA-256). The product's own signature then covers that digest, so `ocm verify` detects any change to the product descriptor — including any change to `references[0].digest`, `name`, `componentName`, or `version`.

```sh
make product   # runs make build → make sign → scripts/product.sh (build, sign, verify, tree)
```

The product component is built into a separate `build/product-ctf/` that holds only the product descriptor. The referenced application is resolved at build time via `build/resolvers.ocmconfig` but is not copied in (use `--external-component-version-copy-policy copy-or-fail` to copy it).

### Trust limitation

`ocm verify cv` checks only the **product's own signature**. It does not fetch the referenced application or compare `references[0].digest` against the live descriptor. A tampered `build/ctf` (for example a provider change) still passes `make product verify`. Observed on OCM 0.17 and unchanged through 0.19.1 (see `bindings/go/cli/cmd/verify/component-version/cmd.go` in the upstream `github.com/open-component-model/ocm` repository).

Mitigations:

- Verify each component independently: `make verify` on the application, then `bash scripts/product.sh verify` on the product.
- Use `ocm transfer cv --recursive`, which **does** enforce reference digests: it fetches the referenced component, recomputes the normalized digest, and fails with `digest mismatch` if they differ.

```sh
# Recursive transfer enforces reference digests at copy time:
ocm transfer cv \
  ctf::./build/product-ctf//github.com/lioramilbaum/product:0.1.0 \
  ctf::./build/release-ctf \
  --recursive \
  --config build/resolvers.ocmconfig
```

The transfer produces a canonical repository containing both components. `make verify` and `bash scripts/product.sh verify` both succeed against it without a resolver config.

Related: [Resolvers](#resolvers) · [Canonical component repositories](#canonical-component-repositories) · [Signing and verification](#signing-and-verification) · [Transfer and transport](#transfer-and-transport)

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
make transfer-plan OCM_REPO=<target>  # review before publishing
make resolvers       # write build/resolvers.ocmconfig mapping github.com/lioramilbaum/** to the local CTF
make manifests       # download and render app manifests from the component
make deploy          # deploy the application to the current cluster (requires KUBECONFIG)
make cluster-up      # create or reuse the kind cluster; writes build/e2e/kubeconfig (requires docker)
make e2e-run         # run e2e against an existing cluster
make cluster-down    # delete the kind cluster
make e2e             # spin up kind cluster, deploy, verify pod ready, tear down (requires docker)
make publish OCM_REPO=ghcr.io/<you>/ocm  # transfer to an OCI registry, copying external resources (e.g. the nginx image) as OCI artifacts; optional OCM_REGISTRY_USERNAME/OCM_REGISTRY_PASSWORD
make ownership       # build the ownership demo component and trace the owner of each resource
make sbom            # regenerate the CycloneDX SBOM (build/sbom/hello-world.cdx.json); also run by make build
make product         # build, sign and verify the product component that references the application
```

## Consuming the component

The component typically arrives here via [transfer](#transfer-and-transport) from a build CTF or upstream registry.

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
- Deploy-time configuration: resource metadata (`config resource metadata`), value injection (`manifests applies config values`), rejection of tampered config (`manifests rejects tampered config`), untargeted config (`manifests rejects untargeted config`), and invalid config (`manifests rejects invalid config`)
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
- Kubernetes component discovery: `discovery selects image variants`, `readme documents kubernetes component discovery`
- Ownership: `ownership records owner`, `ownership record is deterministic`, `ownership survives transfer`, `ownership trace reports owner`, `readme documents ownership`

## CI

CI runs on `ubuntu-latest` (linux/amd64) inside the devcontainer across three workflows:

- **`ci.yaml`** — runs on every push and pull request to `main`: lint and unit tests.
- **`release.yaml`** — triggered by a `v*.*.*` tag or `workflow_dispatch` with a semver `version` input. Runs tests, then builds and signs the OCM component with `OCM_SIGNING_KEY`, uploads a `application-ctf` artifact, and on tags publishes the component to `ghcr.io/<owner>/ocm` and creates a GitHub release.
- **`e2e.yaml`** — runs on every push and pull request to `main`. A `package` job builds and signs the component with an auto-generated dev key and uploads it. A `deploy` job downloads it, verifies the signature, and runs the e2e in isolation: it creates the kind cluster and pre-pulls the rendered manifest images into the kind nodes, then blocks new outbound connections from the kind network with an iptables `DOCKER-USER` rule and starts a `tcpdump` capture on the kind bridge. It runs `make e2e-run` against the cluster, then removes the rule, stops the capture, and fails if any packet left the private ranges for the public internet. The pcap and tcpdump text are uploaded as the `application-e2e-egress-evidence` artifact.

Required repository secrets: `OCM_SIGNING_KEY` (RSA private key PEM).

## Notes

- `make build` and `make test` require Docker Hub access to resolve `nginx:1.31-alpine`. If Docker Hub is unavailable, builds will fail.
