# Component References

A **component reference** (`componentReferences`) declares that one component version depends on another by name, version, and digest. OCM calls the set of a product's component versions its [Software Bill of Delivery](https://ocm.software/docs/how-to/model-products/).

This repository adds `github.com/lioramilbaum/product` — a product component that references the `github.com/lioramilbaum/application` component. Its constructor is `components/product/component-constructor.yaml`:

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

`bash scripts/product.sh` takes one of these subcommands; with no argument it runs all four in order:

- `build` builds `build/product-ctf/` and resolves the application reference
- `sign` signs the product component
- `verify` checks the product's own signature
- `tree` prints the product with the referenced application nested beneath it

What to look for in the `tree` output: the application appears as a child of the product, and its version matches the product's.

```text
 NESTING  COMPONENT                            VERSION  PROVIDER                 IDENTITY
 └─ ●     github.com/lioramilbaum/product      0.1.0    github.com/lioramilbaum  name=github.com/lioramilbaum/product,version=0.1.0
    └─    github.com/lioramilbaum/application  0.1.0    github.com/lioramilbaum  name=github.com/lioramilbaum/application,version=0.1.0
```

The product component is built into a separate `build/product-ctf/` that holds only the product descriptor. The referenced application is resolved at build time via `build/resolvers.ocmconfig` but is not copied in (use `--external-component-version-copy-policy copy-or-fail` to copy it).

### Prerequisites

- `make product` depends on `build sign`, so the application must be built and signed first.
- Docker Hub access is needed for `nginx:1.31-alpine` (pulled by `make build`).
- OCM CLI >= 0.17.0 and `jq`.
- `scripts/resolvers.sh` writes `build/resolvers.ocmconfig` automatically; no manual resolver config is needed.

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
