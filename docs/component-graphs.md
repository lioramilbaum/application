# Component graphs

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

Related: [Resolvers](repositories.md#resolvers) · [Canonical component repositories](repositories.md#canonical-component-repositories) · [Signing and verification](signing.md#signing-and-verification) · [Transfer and transport](transfer.md#transfer-and-transport)

## Component graphs

A component graph is a set of component versions linked by `componentReferences`. This demo builds a diamond: `github.com/lioramilbaum/graph/platform` references `frontend` and `backend`, and both of those reference the same `runtime` component. The runtime is reachable along two paths, so `ocm get cv --recursive` lists it twice. Each level is built into its own CTF (`build/graph/`), so every reference must be found through a resolver rather than in the same repository. The reference model is described in [Component references](#component-references).

The three constructors: `components/graph/runtime.yaml`, `components/graph/apps.yaml` (frontend and backend in one file) and `components/graph/platform.yaml`:

```yaml
name: github.com/lioramilbaum/graph/runtime
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: runtime-notes
    type: plainText
    version: ${VERSION}
    input:
      type: UTF8/v1
      text: "${GRAPH_RUNTIME_TEXT}"
```

```yaml
components:
  - name: github.com/lioramilbaum/graph/frontend
    version: ${VERSION}
    provider:
      name: github.com/lioramilbaum
    componentReferences:
      - name: runtime
        componentName: github.com/lioramilbaum/graph/runtime
        version: ${VERSION}
    resources:
      - name: frontend-notes
        type: plainText
        version: ${VERSION}
        input:
          type: UTF8/v1
          text: "frontend v${VERSION}"
  - name: github.com/lioramilbaum/graph/backend
    version: ${VERSION}
    provider:
      name: github.com/lioramilbaum
    componentReferences:
      - name: runtime
        componentName: github.com/lioramilbaum/graph/runtime
        version: ${VERSION}
    resources:
      - name: backend-notes
        type: plainText
        version: ${VERSION}
        input:
          type: UTF8/v1
          text: "backend v${VERSION}"
```

```yaml
name: github.com/lioramilbaum/graph/platform
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
componentReferences:
  - name: frontend
    componentName: github.com/lioramilbaum/graph/frontend
    version: ${VERSION}
  - name: backend
    componentName: github.com/lioramilbaum/graph/backend
    version: ${VERSION}
```

```sh
make graph   # build the three CTFs, then show the tree, edges, resolver order, transfers and the tamper check; offline
```

### Resolver order

`scripts/graph.sh` writes `build/graph/resolvers.ocmconfig` with two entries: `github.com/lioramilbaum/graph/runtime` maps to the base CTF, and `github.com/lioramilbaum/graph/*` maps to the apps CTF. A resolver is tried in list order and **first match wins**, with no fallback to later entries. The specific runtime pattern must therefore come before the wildcard. If the wildcard comes first, it matches runtime, the apps CTF does not contain it, and `ocm get cv --recursive` fails. Resolvers are described in [Resolvers](repositories.md#resolvers).

### Flat and recursive transfer

`make graph` transfers the platform twice, once without and once with `--recursive`, and then checks each result with no resolver config:

| Transfer | Command | Repositories in target | `get cv --recursive` on target, no resolver |
|---|---|---|---|
| flat | `ocm transfer cv <platform> ctf::build/graph/flat-ctf` | 1 (platform only) | fails |
| recursive | `ocm transfer cv <platform> ctf::build/graph/release-ctf --recursive` | 4 (platform, frontend, backend, runtime) | succeeds |

The flat copy is not self-contained: its references point at components the target does not hold. The recursive copy walks the graph and writes all four components, so it works offline. Transfers are described in [Transfer and transport](transfer.md#transfer-and-transport).

### Transitive digests

Each `componentReferences` entry stores the digest of the referenced descriptor. `ocm transfer cv --recursive` walks the graph and recomputes each digest, so a transitive component that changed after its parent recorded it fails the transfer with `digest mismatch`. `make graph` demonstrates this by replacing the runtime in a copy of the base CTF and transferring the platform again. The flat transfer does not walk references and does not detect the change. The digests use the same normalisation as the signature in [Signing and verification](signing.md#signing-and-verification).

## Version selection

A **component version** is part of a component's identity — a component version reference is `<name>:<version>`. Consumers pick versions by constraint; producers only publish exact versions.

OCM's default versioning scheme is **loose-semver**: any string that `golang.org/x/mod/semver` accepts, plus relaxed two-part `MAJOR.MINOR` forms. The resulting ordering is numeric: `0.10.0 > 0.2.0`.

See also the [configure-versioning tutorial](https://ocm.software/docs/tutorials/configure-versioning/) and the [versioning-configuration reference](https://ocm.software/docs/reference/versioning-configuration/).

### Demo component

`components/versions/component-constructor.yaml`:

```yaml
name: github.com/lioramilbaum/versions-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: release-notes
    type: blob
    version: ${VERSION}
    input:
      type: utf8
      text: "github.com/lioramilbaum/versions-demo ${VERSION}"
```

```sh
make versions   # builds build/versions-ctf (releases) and build/versions-nightly-ctf (nightlies)
```

Release versions in `build/versions-ctf`: `0.1.0 0.2.0 0.10.0 1.0.0 1.1.0-rc.1`  
Nightly versions in `build/versions-nightly-ctf`: `r2 r9 r10 r100`

Expected output:

```text
release  all                 1.1.0-rc.1 1.0.0 0.10.0 0.2.0 0.1.0
release  latest              1.1.0-rc.1
release  latest >= 0.0.0     1.0.0
release  ^0.1                0.1.0
release  >= 0.2.0, < 1.0.0   0.10.0 0.2.0
release  1.x                 1.0.0
nightly  all                 r100 r10 r9 r2
nightly  latest              r100
nightly  all (no scheme)     r9 r2 r100 r10
nightly  latest (no scheme)  r9
```

### Constraints

`ocm get cv <repo>//<name> --constraint '<range>'` uses [Masterminds semver](https://github.com/Masterminds/semver) syntax:

| Query | Result |
|---|---|
| *(none)* | `1.1.0-rc.1 1.0.0 0.10.0 0.2.0 0.1.0` |
| `^0.1` | `0.1.0` |
| `>= 0.2.0, < 1.0.0` | `0.10.0 0.2.0` |
| `1.x` | `1.0.0` |
| `>= 9.0.0` | error: no match |

Results are returned newest-first, ordered numerically (`0.10.0 > 0.2.0`). A constraint that matches nothing exits 1 with `no roots`.

### Pre-releases and --latest

The default constraint `> 0.0.0-0` includes pre-releases, so `--latest` returns `1.1.0-rc.1`. To get the latest stable release, add `--constraint '>= 0.0.0'`:

```sh
ocm get cv "ctf::./build/versions-ctf//github.com/lioramilbaum/versions-demo" \
  --constraint '>= 0.0.0' --latest
# 1.0.0
```

Constraints without a pre-release suffix (`1.x`, `>= 1.0.0`) exclude pre-releases; `>= 1.1.0-0` opts in.

### Versioning schemes

For non-semver version strings, configure a custom scheme. `components/versions/versioning.ocmconfig`:

```yaml
type: generic.config.ocm.software/v1
configurations:
  - type: versioning.config.ocm.software/v1alpha1
    schemes:
      - name: build-number
        pattern: '^r(?P<build>\d+)$'
        comparisonGroups: [build]
```

Schemes are **consumer-side config**: pass `--config versioning.ocmconfig` to `ocm add cv` (validates the version string) and to `ocm get cv` (defines the ordering).

Configuring any scheme drops the built-in `loose-semver` scheme. `build/versions-nightly-ctf` therefore rejects `1.0.0`. Add `- builtin: loose-semver` under `schemes` to accept both formats in the same repo.

Without the config, the nightly CTF reads as **reverse lexical** order: `r9 r2 r100 r10`, with `--latest` returning `r9`. Use `ocm get config` to inspect the active schemes.

CalVer strings like `2026.03.15` parse as loose-semver already (no scheme needed). Avoid uppercase letters and `+` in version strings — OCI tag rules require lowercase and treat `+` specially.

### Where constraints apply

| Context | How versions are filtered |
|---|---|
| CLI `--constraint` / `--latest` | Masterminds semver range against the active scheme |
| Resolver `versionConstraint` | Same; picks the resolver entry — see [Resolvers](repositories.md#resolvers) |
| Controller `Component.spec.semver` | Always uses loose-semver, ignores custom schemes — see [Kubernetes controller](kubernetes.md#kubernetes-controller); `semverFilter` is a regex; `downgradePolicy: Deny` is the default |
| `componentReferences` | Exact versions only; `^0.1` fails — see [Component References](#component-references) |

### Limitations

- `--semver-constraint` (OCM ≤ 0.17) was renamed to `--constraint` in 0.19.0 with no alias; versioning schemes also need ≥ 0.19.0. `scripts/versions.sh` gates on this and exits early with a clear message on older binaries.
- Non-semver versions cannot be used in `<name>:<version>` syntax. `ocm download resource …:r100` fails with `invalid semantic version`; `ocm get cv …:r10` mangles the component name. Select non-semver versions with `--latest` or `--constraint`; `ocm transfer cv` handles them correctly.

Related: [Resolvers](repositories.md#resolvers) · [Kubernetes controller](kubernetes.md#kubernetes-controller) · [Component identity](architecture.md#component-identity) · [Transfer and transport](transfer.md#transfer-and-transport)
