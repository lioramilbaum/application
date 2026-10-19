# Signing

## Signing and verification

The [OCM signing and verification](https://ocm.software/docs/concepts/signing-and-verification/)
model signs the component descriptor, not the artifact bytes directly. `ocm sign cv` normalizes
the descriptor with `jsonNormalisation/v4alpha1` (JSON canonicalization after dropping excluded
fields), hashes the result with `SHA-256`, and signs the hash with `RSASSA-PSS`. The signature
is stored in the descriptor's `signatures` list under the name `default` (or `sigstore` for
keyless signing). `ocm verify cv` recomputes the digest from the normalized descriptor and
checks it against the stored signature using the public key from `build/verify.ocmconfig`. It
does not download resources. Content integrity at deploy time is enforced separately by
`manifests.sh`, which rejects any image reference whose digest differs from the one recorded in
the component descriptor.

Inspect the signature of the built component:

```bash
ocm get cv ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0 -o json \
  | jq '.[0].signatures[0]'
```

Each resource has a `genericBlobDigest/v1` digest that the signature binds. The signature
covers only the fields that survive normalization:

### What the signature covers

| Field | Signed? | Effect of changing it after signing |
|---|---|---|
| `component.name`, `version`, `provider` | yes | `make verify` fails with `digest mismatch` |
| Resource `name`, `version`, `type`, `relation`, `digest` | yes | `make verify` fails with `digest mismatch` |
| Source `name`, `version`, `type` | yes | `make verify` fails with `digest mismatch` |
| Label with `signing: true` | yes | `make verify` fails with `digest mismatch` |
| Component reference (`name`, `componentName`, `version`, `digest`) | yes | `make verify` fails with `digest mismatch` |
| Label **without** `signing: true` | **no** | `make verify` still passes |
| Resource and source `access` | **no** | `make verify` still passes |
| `component.repositoryContexts` | **no** | `make verify` still passes (enables transfer) |
| `srcRefs` | **no** | `make verify` still passes |
| `signatures` | **no** | not part of what is signed |

Three consequences for this component:

- `application.lioramilbaum.github.com/tier` has no `signing: true`. Anyone who can write to
  the repository can change its value and `make verify` still passes. Do not base trust
  decisions on unsigned labels. To protect a label, add `signing: true` to it before signing.
- The `application-source` commit SHA lives in the source's `access`, so it is not signed.
  The source entry (name, version, type) is signed; the commit reference is not.
- The image `access.imageReference` is not signed, which is why transfer can rewrite
  references without breaking signatures. The image's `digest` is signed, and `manifests.sh`
  enforces it at deploy time.

### Trust models

| Model | What the verifier trusts | Config in this repo |
|---|---|---|
| Key pinning (plain encoding) | The public key file you provide | `RSA/v1alpha1` consumer in `build/verify.ocmconfig` |
| Certificate chain (PEM encoding, early access) | A certificate chain from a trusted CA | `signatureEncodingPolicy: PEM` in `RSASigningConfiguration`; see [Certificate-chain signing](certificate-chain-signing.md#certificate-chain-signing) |
| Identity-based (Sigstore keyless) | A Fulcio certificate matching issuer and identity regexp | `SigstoreVerificationConfiguration/v1alpha1` in `build/verify-sigstore.ocmconfig` |
| OpenPGP key (GPG) | The OpenPGP public key you provide | `GPG/v1alpha1` consumer in `build/gpg/verify.ocmconfig`; see [GPG signing](gpg-signing.md#gpg-signing) |

Key pinning is the simplest: rotate the key by deleting the existing key files and re-running
`scripts/keys.sh`, then re-signing. Sigstore keyless signing records the certificate in a Rekor transparency log, so
verification does not require a long-lived key: `SIGNING_METHOD=sigstore make sign` uses the
OIDC token from the CI environment.

## Signing normalisation

`ocm sign cv` does not hash the descriptor as stored. It first normalises it with `jsonNormalisation/v4alpha1` and signs the SHA-256 of the result. The normalised form keeps the fields that are meant to be signed and drops the rest:

- Kept: component `name`, `version`, `provider`, and labels with `signing: true`; for each resource its `name`, `version`, `type`, `relation` and `digest`; for each source and component reference the same kind of fields.
- Dropped: `meta`, `signatures`, `nestedDigests`, `repositoryContexts`, every `access` block, `srcRefs`, and every label without `signing: true`.
- The keys are sorted and the JSON is compact before hashing.

The demo component changes one thing per variant so that the effect of each rule is visible in the digests:

```yaml
name: github.com/lioramilbaum/normalisation-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
labels:
  - name: normalisation.lioramilbaum.github.com/note
    value: "${NORM_NOTE}"
  - name: normalisation.lioramilbaum.github.com/channel
    value: "${NORM_CHANNEL}"
    signing: true
resources:
  - name: payload
    type: plainText
    version: ${VERSION}
    input:
      type: UTF8/v1
      text: "${NORM_PAYLOAD}"
```

`make normalisation` builds the application CTF, prints its normalised descriptor, and checks it against `ocm sign cv --dry-run`. It then builds four variants of the demo component and compares their digests:

| Variant | Change | resource-changed | component-changed | Explanation |
|---|---|---|---|---|
| `base` | none | - | - | reference point |
| `unsigned-label` | `note` label changed (no `signing`) | no | no | labels without `signing: true` are dropped from the normalised form |
| `signed-label` | `channel` label changed (`signing: true`) | no | yes | a signed label is part of the component digest, but not of any resource digest |
| `blob` | `payload` text changed | yes | yes | the resource digest changes, and the component digest follows it |

The reimplementation in `components/normalisation/jsonNormalisation-v4alpha1.jq` reproduces the OCM digest for every variant: the `jq-matches-ocm` column is `yes` on each row. The jq filter is a reading aid, not a second source of truth. When OCM changes the rules, the `make normalisation` check fails.

Inspect the digest OCM computes without signing:

```bash
ocm sign cv --config build/sign.ocmconfig --dry-run -o json \
  ctf::./build/ctf//github.com/lioramilbaum/application:0.1.0 | jq -r '.digest.value'
```

Only `jsonNormalisation/v4alpha1` is available in this OCM CLI. The older `jsonNormalisation/v1` is rejected: `ocm sign cv --normalisation jsonNormalisation/v1` fails with `unknown normalisation algorithm`. A signature made with that algorithm cannot be produced or verified here.

The rules are described in [Signing and verification](#signing-and-verification): unsigned labels, access and `srcRefs` are outside the signature, and so is anything the signature table there lists as "no".

## Real signing keys

Dev keys are generated once into `build/keys/` and are gitignored. For production:

```bash
SIGNING_KEY=/path/to/private.pem VERIFY_KEY=/path/to/public.pem make sign verify
```

## Keyless signing (Sigstore)

To sign with Sigstore/Cosign keyless signing (requires OIDC token):

```bash
SIGNING_METHOD=sigstore make build sign verify
```

Signature names:

- `default`: RSA signature (default behavior)
- `sigstore`: Sigstore keyless signature (when `SIGNING_METHOD=sigstore`)

For local testing with Sigstore:

```bash
export SIGSTORE_ID_TOKEN="<your-oidc-token>"
SIGNING_METHOD=sigstore make sign verify
```

In GitHub Actions, add `id-token: write` to the job's `permissions:` block. The CI/CD will use GitHub's OIDC provider to acquire a token automatically.

**Note on certificate validation**: OCM does not currently honour the `tokenFile` configuration option; use `SIGSTORE_ID_TOKEN` environment variable instead.
