# OCI images

`ociImage` is the OCM resource type for a container image. OCM stores the image in the component repository as a `LocalBlob/v1` access, so the image is signed, transferred and downloaded with the component instead of being pulled from a registry when the component is consumed.

OCM 0.19.1 has no `ociImage` input type: a constructor with `input: type: ociImage` fails with `no input method resolvable for input specification of type ociImage`. The demo therefore builds each image from a local OCI image layout tar, using the `file` input type with media type `application/vnd.ocm.software.oci.layout.v1+tar`. The demo runs offline.

### Demo component

```yaml
# Demo component for OCI image resources (ociImage from local OCI layout tars).
name: github.com/lioramilbaum/oci-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: hello-image
    type: ociImage
    version: ${VERSION}
    extraIdentity:
      architecture: amd64
    input:
      type: file
      path: ./hello-oci-amd64.oci.tar
      mediaType: application/vnd.ocm.software.oci.layout.v1+tar
  - name: hello-image
    type: ociImage
    version: ${VERSION}
    extraIdentity:
      architecture: arm64
    input:
      type: file
      path: ./hello-oci-arm64.oci.tar
      mediaType: application/vnd.ocm.software.oci.layout.v1+tar
  - name: hello-image-multiarch
    type: ociImage
    version: ${VERSION}
    input:
      type: file
      path: ./hello-oci-multiarch.oci.tar
      mediaType: application/vnd.ocm.software.oci.layout.v1+tar
```

```bash
make oci   # build, sign, verify and download the OCI image demo; offline (requires python3, tar)
```

`hello-image` appears twice, once per architecture, with `extraIdentity.architecture` set to `amd64` and `arm64`. `hello-image-multiarch` is an OCI image index that refers to both single-architecture images. `make oci` builds, signs, verifies and downloads all three resources, then prints one `resource` row for each.

### Layouts

`components/oci/layout.py` writes the three tars that the constructor references, and the tars are committed. The generator is deterministic: USTAR format, `mtime` 0, uid and gid 0, sorted entries and canonical JSON. The test suite checks that a fresh run reproduces the committed tars byte for byte.

An OCI image layout holds `oci-layout`, `index.json` and `blobs/sha256/<hex>`, where every blob is named by its own digest:

- A single-architecture image: `index.json` lists one manifest. The manifest points to a config (`architecture`, `os`, `rootfs.diff_ids`) and to one layer, a tar that holds `hello.txt` with the content `hello from <arch>`.
- The multi-architecture image: `index.json` lists one image index, and that index lists the two single-architecture manifests, each with a `platform` entry (`architecture`, `os`).

### Inside the resource

The descriptor records each image as `access: LocalBlob/v1`, with the blob digest as `localReference` and the manifest (or index) media type as `mediaType`. The resource digest is that same digest: the manifest digest for an architecture and the index digest for `hello-image-multiarch`.

`ocm download resource` writes the layout back out with its own `index.json` annotations, so the verifier checks each blob against its file name rather than comparing `index.json` byte for byte. `scripts/oci.sh inspect` prints the verified content as `image` and `layer` rows (fields are tab-separated):

```text
image  hello-image  amd64  application/vnd.oci.image.manifest.v1+json  sha256:<manifest digest>
layer  hello-image  amd64  sha256:<layer digest>  hello from amd64
```

`download` and `inspect` verify the signature first, so they fail on an unsigned component.

### Multi-arch

Each single-architecture resource carries `extraIdentity.architecture`, so it can be selected by identity, for example `ocm download resource --identity name=hello-image,architecture=arm64`. The index `hello-image-multiarch` has no extra identity. A consumer that needs every platform downloads the index, and the `platform` entries of its manifests say which variant is which.

### Transfer

`scripts/oci.sh plan` dry-runs `ocm transfer cv` to `oci::http://registry.example.invalid/mirror` in three modes and prints the transformation count for each type. The plan, review and replay workflow is described in [Transfer and transport](transfer.md#transfer-and-transport):

| Mode | Flags | Result with OCM 0.19.1 |
|---|---|---|
| `plain` | none | three `OCIAddLocalResource/v1alpha1`: the images stay `LocalBlob/v1` |
| `copy-resources` | `--copy-resources` | same as `plain`: the images are local blobs, not external resources, so nothing is copied |
| `uploader` | `--config components/oci/relocate.ocmconfig` | three `AddOCIArtifact/v1alpha1`: each image is pushed as its own `ociArtifact/v1` |

### Localization

Image references are localized at three levels:

- **Build time**: `${VAR}` substitution in the constructor (`ocm add cv` expands `${VERSION}` here). This works for any string in the constructor.
- **Transfer time**: `components/oci/relocate.ocmconfig` holds `oci.uploader.transfer.config.ocm.software/v1alpha1` entries. Their `imageReference` is a CEL expression over the target, so each image is pushed as `<target>/mirror/hello-image:<version>-<arch>` (the index as `<version>`). The descriptor keeps the same digests, so the signature survives. `scripts/oci.sh relocate` is a dry run: it prints each access and the expression that OCM evaluates when the plan is replayed. A replay against a registry rewrites the accesses to `ociArtifact/v1`, keeps the digests, and `ocm verify` still passes on the target. The `relocate` rows show the expression, not the pushed references, because the references exist only after a push.
- **Deploy time**: `localizationConfig` rules map image resources to container fields, and `scripts/manifests.sh` renders them, as in the `hello-world` component (see [How it works](architecture.md#how-it-works)).

`ocm add cv --config` does NOT substitute image references. Its file is OCM configuration (credentials, signing, and so on). The uploader entries in `relocate.ocmconfig` apply to `ocm transfer cv`.

### Limitations

- OCM 0.19.1 has no `ociImage` input type, so images come from layout tars.
- A local image reaches a registry only through an uploader entry with an explicit `imageReference`. `--copy-resources` does not move local images.
- The `imageReference` expressions use `target.baseUrl`, so they work for `oci::` targets only. A CTF target fails with `no such key: baseUrl`.
- `download` and `inspect` require a valid signature.
