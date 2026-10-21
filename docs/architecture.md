# Architecture

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
- **hello-world-sbom**: CycloneDX 1.6 software bill of materials generated from the constructor (see [Software Bills of Materials](ownership-and-sbom.md#software-bills-of-materials))
- **deploy-bundle**: directoryTree containing the deployment scripts and OCM component descriptor
- **application-source**: git source reference with the repository URL and commit SHA

The key concept is **digest-pinned images**. At build time, the OCM component records the nginx image with the digest already pinned in `component-constructor.yaml` (e.g., `docker.io/library/nginx:1.31-alpine@sha256:138af8...`). At deploy time, `manifests.sh` downloads the manifest template and the localization rules from the signed component and checks both against their descriptor digests. It then generates a `kustomization.yaml` with JSON 6902 patches that set the target container's image to the pinned digest, and renders the result with `kubectl kustomize`. The rules say which container in which workload gets which image resource, so the mapping is covered by the signature too. The `HELLO_WORLD_IMAGE` placeholder in the manifest is a sentinel: rendering fails if it survives. This ensures reproducible, tamper-evident deployments: the deployed image is cryptographically tied to the signed component, and no one can swap the image or its target field without invalidating the signature. See [Signing and verification](signing.md#signing-and-verification) for what the signature covers.

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
Git tag `v0.1.0` becomes component version `0.1.0`. This is OCM's default `loose-semver` scheme; see [Version selection](component-graphs.md#version-selection) for constraints and custom schemes.

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
| resource `hello-world-kustomize` | `name=hello-world-kustomize,version=0.1.0` | `github.com/lioramilbaum/application:0.1.0:resource/hello-world-kustomize` |
| resource `hello-world-rgd` | `name=hello-world-rgd,version=0.1.0` | `github.com/lioramilbaum/application:0.1.0:resource/hello-world-rgd` |
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
[Signing and verification](signing.md#signing-and-verification) for what labels are signed.

### Selecting an artifact

`ocm download resource` takes `--identity key=value,...` pairs. OCM prefers an exact match, falls
back to a subset match, and requires exactly one candidate:

| `--identity` | Result |
|---|---|
| `name=deploy-bundle` | OK (subset match, one candidate) |
| `name=deploy-bundle,version=0.1.0` | OK (exact match) |
| `version=0.1.0` | error: `expected exactly one resource candidate to download, got 9` |
| `name=deploy-bundle,version=9.9.9` | error: `expected exactly one resource candidate to download, got 0` |
| `name=hello-world-image` | error: `expected exactly one resource candidate to download, got 2` |
| `name=hello-world-image,architecture=amd64` | OK (subset match, one candidate) |

`scripts/manifests.sh` does not pass `--identity` for the image. It selects the `hello-world-image`
resource whose `extraIdentity.architecture` matches `TARGET_ARCH` (default: the host architecture
from `scripts/lib.sh`) and fails unless exactly one candidate matches.

This is distinct from the *consumer identity* in [Credential system](credentials.md#credential-system), which
identifies the endpoint a credential belongs to.

## Localization

Image references change at three steps between build and deploy: build time (`${VAR}` substitution in the constructor), transfer time (the `imageReference` of an uploader config, see [Uploader configs](transfer.md#uploader-configs)), and deploy time (`localizationConfig` rules applied by `scripts/manifests.sh`, see [How it works](#how-it-works)). The transfer-time step is demonstrated with a real image in [OCI images](oci-images.md#oci-images).

## Source provenance

The component includes a source reference (`application-source`) with:

- **Repository URL**: the GitHub repository
- **Commit SHA**: the exact git commit used to build the component

The commit SHA is recorded in the source's `access` field, which is excluded from normalization and therefore not signed — see [Signing and verification](signing.md#signing-and-verification).

The commit SHA is determined by:

1. `SOURCE_COMMIT` environment variable, if set
2. Otherwise, the current HEAD of the git repository (via `git rev-parse HEAD`)

Note: SOURCE_COMMIT must be a 40-character hex string (a full git commit SHA). A dirty working tree is not reflected in the source reference — only the commit SHA matters.

The commit identifies the source but does not carry it: if the repository is rewritten or deleted, the reference is dead, and the signed descriptor does not bind the commit. [Git repositories](git-repositories.md#git-repositories) escrows the source tree in the component with a `Git/v1` input and binds its commit with a signed label.
