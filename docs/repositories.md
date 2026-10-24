# Repositories

## Resolvers

A component reference does not carry a repository address. The repository on the command line locates the root component only. Resolvers map component name patterns to repositories, so `get cv --recursive`, `transfer cv --recursive`, and `add cv` can find the components that a component references. An explicit repository in a `componentReferences` entry always wins for that component. See the [OCM resolvers](https://ocm.software/docs/concepts/resolvers/) documentation for the full model.

The application component itself has no `componentReferences`. `scripts/product.sh` uses `build/resolvers.ocmconfig` to resolve the application when building the product component — see [Component References](product.md#component-references). Resolvers also matter to consumers that reference `github.com/lioramilbaum/application`.

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

Each resource in a component descriptor has an [`access:`](https://ocm.software/docs/concepts/resource-repositories/) specification that says where the artifact lives and how to retrieve it. OCM uses that type to route downloads and uploads to the right backend — an OCI registry, a Helm repository, cloud storage, or a [plugin-backed](plugins.md#plugin-system) store.

### Resources in this component

| Resource | Relation | Access type | Where the bytes live |
|---|---|---|---|
| `hello-world-image` | external | `OCIImage/v1` | Docker Hub — `docker.io/library/nginx:1.31-alpine@sha256:…` |
| `hello-world-manifests` | local | `LocalBlob/v1` | inside the component repository (CTF or OCI layer) |
| `hello-world-localization` | local | `LocalBlob/v1` | inside the component repository |
| `deploy-bundle` | local | `LocalBlob/v1` | inside the component repository |
| `hello-world-sbom` | local | `LocalBlob/v1` | inside the component repository |
| `application-source` (source) | — | `GitHub/v1` | GitHub — referenced only, never copied |

Helm charts (`helm/v1` input, `Helm/v1` access): see [Helm charts](helm-charts.md#helm-charts).

HTTP downloads (`Wget/v1` input and access): see [HTTP resources](http-resources.md#http-resources).

Git repositories (`Git/v1` input, access and sources): see [Git repositories](git-repositories.md#git-repositories).

OCI image layouts: see [OCI images](oci-images.md#oci-images).

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

`make publish` routes external resources through `uploaders.ocmconfig` (`oci.uploader.transfer.config.ocm.software/v1alpha1` entries) so the published component doesn't depend on Docker Hub and the image remains pullable. `--copy-resources --upload-as ociArtifact` is the deprecated equivalent of this config, still accepted in OCM 0.21.0.

Sources (`GitHub/v1`) are never copied by any transfer mode.

The signature covers resource digests, not access specs, so `make verify` still passes after transfer — the digest is unchanged even when the image moves to a new registry. See [Signing and verification](signing.md#signing-and-verification) for the full list of signed and unsigned fields.

`--copy-resources` reads from Docker Hub, so source-side registry credentials come from the `DockerConfig/v1` fallback described in [Credential system](credentials.md#credential-system).

See [Transfer and transport](transfer.md#transfer-and-transport) for the dry-run → review → replay workflow.

## Canonical component repositories

A [canonical repository](https://ocm.software/docs/concepts/canonical-component-repositories/)
holds every component of a component graph, so `get cv --recursive` and `transfer cv --recursive`
need no resolvers. This component has no references, so any repository that holds it is canonical. The product component in `build/product-ctf/` is not canonical; `ocm transfer cv --recursive` into a fresh repository makes both components canonical — see [Component References](product.md#component-references).

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
