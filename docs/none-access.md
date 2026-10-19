# Resources without access (None)

A resource with `access: type: None` is listed in the component, but OCM has no access to fetch its bytes. It records that an artifact exists and where it belongs: provenance records, attestations and artifacts that live outside OCM.

**`None` resources are not signed.** Before hashing, `jsonNormalisation/v4alpha1` drops the `digest` of every resource whose access type is `None` (see [Signing normalisation](signing.md#signing-normalisation)). A digest written for a `None` resource therefore changes neither the component digest nor the signature. OCM also warns that it cannot use that digest. To bind the external bytes to the signature, put their sha256 in a label with `signing: true` (see [Binding external bytes](#binding-external-bytes)).

### Demo component

`components/none-access/component-constructor.yaml`:

```yaml
name: github.com/lioramilbaum/none-access-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: release-notes
    type: plainText
    version: ${VERSION}
    input:
      type: UTF8/v1
      text: "none-access-demo v${VERSION}"
  - name: provenance
    type: blob
    version: ${VERSION}
    relation: external
    access:
      type: None
    labels:
      - name: none-access.lioramilbaum.github.com/sha256
        value: "c2b17a7d610d86431dea41e82908b0187166b17990244fcd5e12a759167eee4e"
        signing: true
```

`release-notes` is an ordinary local input and downloads as usual. `provenance` is the `None` resource. Its bytes are `components/none-access/provenance.json`, which lives outside OCM. The `none-access.lioramilbaum.github.com/sha256` label carries the sha256 of that file.

```sh
make none-access   # build, sign and verify; show the descriptor, download, audit, variants and transfer; offline
```

### Variants

`scripts/none-access.sh variants` builds seven variants of the constructor and reports the access type, whether the resource has a digest, whether the component digest is the same as the base, and the warning from `ocm sign cv --dry-run`:

| Variant | Change | Has digest | Component digest same as base | Sign warning |
|---|---|---|---|---|
| `base` | plain `None`, no digest | no | - | none |
| `digest-a` | `None` with an explicit digest | yes | yes | `digest for resource with empty access not allowed` |
| `digest-b` | `None` with a different explicit digest | yes | yes | `digest for resource with empty access not allowed` |
| `lowercase` | `type: none` | no | yes | `missing digest in resource` |
| `versioned-type` | `None/v1` with a digest | yes | no | none |
| `renamed` | resource named `attestation` | no | no | none |
| `label-changed` | signed label value changed | no | no | none |

The first three rows show that the digest of a `None` resource is not signed: `digest-a` and `digest-b` carry different digests and produce the same component digest as the base. OCM warns about the digest when signing, but the signature does not cover it. The last three rows show what is signed: a digest on a `None/v1` resource, the resource name and the signed label each change the component digest.

### The `None/v1` trap

`None/v1` is not the `None` access type. OCM 0.19.1 treats it as an unknown access type, so normalisation keeps its digest. The `versioned-type` variant has a digest and therefore changes the component digest, and the signature covers it. Write `None` exactly, without a version, to get the behaviour described above.

### `None` and `none`

Normalisation accepts both `None` and the lowercase `none` and drops the digest in both cases. The signing step does not treat them the same way: the lowercase form with no digest reports `missing digest in resource`, while `None` with no digest reports nothing. Write `None` exactly.

### Binding external bytes

The `signing: true` label on `provenance` is part of the signed component. Changing the label, or the file it names, fails `make verify` or the audit. The audit checks the file against the label:

```sh
bash scripts/none-access.sh audit   # verify the signature, then compare provenance.json with the signed label
```

The audit prints `audit passed` and the sha256 when the file matches the label. When the file has been changed, it exits with `audit failed`. The label binds the file only if the file is distributed with the component and checked by the audit; a copy of the component without the file cannot be audited.

### Transfer

`ocm transfer cv` keeps `provenance` as `None`, and so does `--copy-resources`, because there are no bytes to copy. Both transfers verify with the original signature.

### Limitations

- `ocm download resource` fails for `provenance` with `failed to get plugin for typ "None"`. The script reports this as `no-access`.
- The audit only proves that the file matches the label. It does not check where the file came from.

Related: [Signing normalisation](signing.md#signing-normalisation) · [Signing and verification](signing.md#signing-and-verification) · [Transfer and transport](transfer.md#transfer-and-transport)
