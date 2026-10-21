# Version selection

A **component version** is part of a component's identity — a component version reference is `<name>:<version>`. Consumers pick versions by constraint; producers only publish exact versions.

OCM's default versioning scheme is **loose-semver**: any string that `golang.org/x/mod/semver` accepts, plus relaxed two-part `MAJOR.MINOR` forms. The resulting ordering is numeric: `0.10.0 > 0.2.0`.

See also the [configure-versioning tutorial](https://ocm.software/docs/tutorials/configure-versioning/) and the [versioning-configuration reference](https://ocm.software/docs/reference/versioning-configuration/).

### Prerequisites

- OCM CLI >= 0.19.0: `scripts/versions.sh` gates on `get cv --constraint` and exits early with a clear message on older binaries
- `jq`

The demo works offline: no cluster or Docker is needed. The prerequisites for all demos are in [Prerequisites](development.md#prerequisites).

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

`bash scripts/versions.sh` takes one of these subcommands:

- `build` builds both CTFs
- `list [constraint]` lists release versions, optionally filtered by a constraint
- `latest [constraint]` shows the latest release version, optionally filtered by a constraint
- `nightly` lists the nightly versions
- `show` reports the selections the demo makes

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
| `componentReferences` | Exact versions only; `^0.1` fails — see [Component References](product.md#component-references) |

### Limitations

- `--semver-constraint` (OCM ≤ 0.17) was renamed to `--constraint` in 0.19.0 with no alias; versioning schemes also need ≥ 0.19.0. `scripts/versions.sh` gates on this and exits early with a clear message on older binaries.
- Non-semver versions cannot be used in `<name>:<version>` syntax. `ocm download resource …:r100` fails with `invalid semantic version`; `ocm get cv …:r10` mangles the component name. Select non-semver versions with `--latest` or `--constraint`; `ocm transfer cv` handles them correctly.

Related: [Resolvers](repositories.md#resolvers) · [Kubernetes controller](kubernetes.md#kubernetes-controller) · [Component identity](architecture.md#component-identity) · [Transfer and transport](transfer.md#transfer-and-transport)
