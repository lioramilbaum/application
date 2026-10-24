# Local OCI registry

This demo runs a plain-HTTP OCI registry on your machine, pushes a demo component to it, signs and verifies it there, and pulls it back. The registry is a `registry:2` container on `127.0.0.1`, so it needs Docker. `build` does not.

### Demo component

`scripts/registry.sh` writes this constructor to `build/registry/component-constructor.yaml`:

```yaml
# Demo component for local OCI registry demo.
name: github.com/lioramilbaum/registry-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: release-notes
    type: blob
    version: ${VERSION}
    input:
      type: UTF8/v1
      text: "github.com/lioramilbaum/registry-demo ${VERSION}"
```

```bash
make registry                   # start the registry, then build, push, sign, verify, pull and show
bash scripts/registry.sh stop   # remove the container and its data
```

### Start a registry

`scripts/registry.sh start` runs `registry:2@sha256:a3d8…` (pinned by digest) as container `ocm-demo-registry`, published on `127.0.0.1:5055`. It is idempotent: when the container already runs, it waits until the registry answers and prints the repository. Override the defaults with `REGISTRY_NAME`, `REGISTRY_HOST`, `REGISTRY_PORT` and `REGISTRY_PATH`.

### Push

`scripts/registry.sh build` writes the component to `build/registry-ctf` with `ocm add cv`. `scripts/registry.sh push` copies it into the registry with `ocm transfer cv`:

```bash
ocm transfer cv ctf::build/registry-ctf//github.com/lioramilbaum/registry-demo:0.1.0 oci::http://127.0.0.1:5055/ocm
```

The registry has no authentication, so no credentials are needed. Authenticated registries need a consumer configuration; see [Credential system](credentials.md#credential-system).

### Repository identity

The registry address for the component is `oci::http://127.0.0.1:5055/ocm//github.com/lioramilbaum/registry-demo:0.1.0`:

- `oci::` is the optional repository type prefix.
- `http://` selects plain HTTP. Without it OCM uses HTTPS, which fails against this registry.
- `127.0.0.1:5055` is the registry host and port.
- `/ocm` is the base path. It is part of the repository identity.
- `//` separates the repository from the component name.
- `:0.1.0` is the component version. OCI stores it as the tag `0.1.0` of `ocm/component-descriptors/github.com/lioramilbaum/registry-demo`.

The registry catalog lists that repository:

```bash
curl http://127.0.0.1:5055/v2/_catalog
# {"repositories":["ocm/component-descriptors/github.com/lioramilbaum/registry-demo"]}
```

`scripts/registry.sh show` prints the catalog, the component from `ocm get cv`, its resources and its signatures.

### Sign and verify

`scripts/registry.sh sign` runs `ocm sign cv` against the registry copy and stores the signature `default` in its descriptor. `scripts/registry.sh verify` runs `ocm verify cv` with `build/verify.ocmconfig`. The source CTF stays unsigned.

Signing the registry copy again fails with `signature "default" already exists`.

### Re-push overwrites signatures

A second `ocm transfer cv` from the unsigned CTF replaces the registry descriptor and drops the registry signature (OCM 0.19.1). Sign again after each push. See [Transfer and transport](transfer.md#transfer-and-transport) for how transfers carry signatures.

### Pull

`scripts/registry.sh pull` verifies the signature, then runs `ocm download resource` for `release-notes` and checks its sha256 against the descriptor digest. It transfers the component back into a CTF with `ocm transfer cv`:

```text
build/registry/download/release-notes
ctf::build/registry/pulled-ctf
```

### Image layers (OCIImageLayer/v1)

`bash scripts/registry.sh layer` references a single OCI layer blob in the registry from a component, without copying its bytes into the component. It needs OCM ≥ 0.21.0 (#3215). `make registry` runs it after the pull step.

The script pushes a small image to the repository `ocm/layers/release-notes`:

- the layer `build/registry/layer/release-notes.txt`, media type `text/plain`
- an empty config blob `{}`, media type `application/vnd.oci.empty.v1+json`
- an OCI image manifest at tag `0.1.0` that lists the layer

The manifest is pushed alongside the blob. A repository that holds only blobs has no tags, so the manifest makes it an ordinary image repository that tools can list and inspect.

The layer constructor, `build/registry/layer-constructor.yaml`:

```yaml
# Layer demo: the resource references one OCI layer blob by digest; OCM fills in size.
name: github.com/lioramilbaum/registry-layer-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: release-notes-layer
    type: blob
    version: ${VERSION}
    access:
      type: OCIImageLayer/v1
      ref: ${REGISTRY_LAYER_REF}
      mediaType: text/plain
      digest: ${REGISTRY_LAYER_DIGEST}
```

- `ref` is the repository without a tag, `http://127.0.0.1:PORT/ocm/layers/release-notes`. The `http://` scheme is required for the local registry, which serves plain HTTP. The layer is addressed by `digest`, so no tag is needed.
- `size` is not set. OCM reads the layer when the component is added and fills in the size.
- OCM also accepts the legacy alias `ociBlob/v1` for `OCIImageLayer/v1`. This demo uses the canonical name.

`scripts/registry.sh` exports `REGISTRY_LAYER_REF` and `REGISTRY_LAYER_DIGEST` and runs `ocm add cv` with this constructor. The command then signs, verifies and downloads the layer, and checks its sha256 against the descriptor digest. The output is one tab-separated row per step:

```text
layer	ocm/layers/release-notes	sha256:<hex>	<size>
resource	release-notes-layer	OCIImageLayer/v1	sha256:<hex>	<size>
download	release-notes-layer	ok
copied	release-notes-layer	LocalBlob/v1
missing-layer	release-notes-layer	not-found
```

The copy uses the `localblob` uploader, which stores the layer inside the target CTF as `LocalBlob/v1` and keeps the digest as its `localReference`. The copy no longer needs the registry:

```yaml
type: generic.config.ocm.software/v1
configurations:
  - type: localblob.uploader.transfer.config.ocm.software/v1alpha1
    match: resource.access.isType("OCIImageLayer")
```

If `REGISTRY_LAYER_DIGEST` names a digest that the registry does not hold, `ocm add cv` fails with `does not exist`. The script reports that failure as `missing-layer … not-found`.

### Cleanup

`bash scripts/registry.sh stop` removes the container and the registry data. The next `start` begins with an empty registry.

### Limitations

- Plain HTTP only, with no authentication and no TLS. Use it on `127.0.0.1` for demos, not for shared registries.
- Registry data is lost on `stop`.
- `start`, `stop` and `make registry` require a running Docker daemon. `build` works without Docker. `push`, `sign`, `verify`, `pull` and `show` need the registry to be running.
