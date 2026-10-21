# Component graphs

A component graph is a set of component versions linked by `componentReferences`. This demo builds a diamond: `github.com/lioramilbaum/graph/platform` references `frontend` and `backend`, and both of those reference the same `runtime` component. The runtime is reachable along two paths, so `ocm get cv --recursive` lists it twice. Each level is built into its own CTF (`build/graph/`), so every reference must be found through a resolver rather than in the same repository. The reference model is described in [Component references](product.md#component-references).

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
