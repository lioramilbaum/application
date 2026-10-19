# Ownership and SBOMs

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
the resource in a component version you have verified. See [Signing and verification](signing.md#signing-and-verification).

### Transfer

A by-value record travels with its subject, so a transfer that copies the resource also copies its
ownership record. See [Transfer and transport](transfer.md#transfer-and-transport).

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

Related: [Signing and verification](signing.md#signing-and-verification) · [Transfer and transport](transfer.md#transfer-and-transport)
