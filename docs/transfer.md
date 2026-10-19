# Transfer and consumption

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
| External resources (OCI images) | When selected by an uploader | See [Resource repositories](repositories.md#resource-repositories) |
| Sources | Never | References only; content stays in origin VCS |
| Referenced components | With `--recursive` | See [Resolvers](repositories.md#resolvers) |

Signatures travel inside the descriptor. Because OCM verification uses the normalised
descriptor (not the raw bytes), re-uploading resources or rewriting their access does not
invalidate the signature. See [Signing and verification](signing.md#signing-and-verification).

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
- `--identity name=deploy-bundle` selects the resource by artifact identity (subset match — only one resource has that name); see [Component identity](architecture.md#component-identity).
