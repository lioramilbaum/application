# Certificate-chain signing

[Signing and verification](signing.md#signing-and-verification) pins a public key: `build/verify.ocmconfig` holds the signer's `public.pem`, so a new signing key means a new verifier config for every consumer. With PEM encoding the signer embeds its X.509 certificate chain in the signature, and the verifier pins a root CA instead. Any leaf certificate that chains to that root and is valid for code signing is accepted, so the signing key can change without touching consumers. See [certificate chain trust](https://ocm.software/docs/concepts/signing-and-verification/#certificate-chain-trust-pem-encoding) and the [PEM tutorial](https://ocm.software/docs/tutorials/signing/certificate-chains-pem/).

### Demo component

`components/pki/component-constructor.yaml`:

```yaml
name: github.com/lioramilbaum/pki-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: release-notes
    type: blob
    version: ${VERSION}
    input:
      type: utf8
      text: "github.com/lioramilbaum/pki-demo ${VERSION}"
```

```sh
make pki   # create a demo CA, build, sign with a PEM signature, verify against the root CA; offline
```

`make pki` writes the certificates to `build/pki/certs/`, the configs to `build/pki/`, and the component archive to `build/pki-ctf`. The signature is named `pki`, so it can sit next to the plain `default` signature on the same component; each name has its own consumer identity (`signature: pki`).

### Certificates

| File | Role | Validity | Embedded in the signature? |
|---|---|---|---|
| `root.crt` | Self-signed root CA (`CA:TRUE`); the verifier's trust anchor | 10 years | no, never |
| `intermediate.crt` | Intermediate CA (`CA:TRUE, pathlen:0`), issued by the root | 5 years | yes |
| `leaf.crt` / `leaf.key` | Signer certificate (`extendedKeyUsage = codeSigning`), issued by the intermediate | 30 days | yes |
| `chain.pem` | `leaf.crt` then `intermediate.crt`, root excluded; the signer config points at it | — | — |

`scripts/pki.sh` keeps the root and intermediate across runs and reissues the leaf under the same intermediate when it is missing or expires within a day, so `build/pki/verify.ocmconfig` stays valid.

### Configuration

The signer config (`build/pki/sign.ocmconfig`) holds the leaf key, the chain, and a signer with `signatureEncodingPolicy: PEM`:

```yaml
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: pki
        credentials:
          - type: RSACredentials/v1
            privateKeyPEMFile: /abs/path/build/pki/certs/leaf.key
            publicKeyPEMFile: /abs/path/build/pki/certs/chain.pem
  - type: signing.config.ocm.software/v1alpha1
    signer:
      type: RSASigningConfiguration/v1alpha1
      signatureAlgorithm: RSASSA-PSS
      signatureEncodingPolicy: PEM
```

The verifier config (`build/pki/verify.ocmconfig`) holds only the root CA, in `publicKeyPEMFile`. It needs no `verifier` entry: OCM selects PEM verification from the signature's `application/x-pem-file` media type.

`bash scripts/pki.sh show` prints the stored signature and the embedded chain:

```text
signature	pki	RSASSA-PSS	application/x-pem-file
digest	jsonNormalisation/v4alpha1	SHA-256	<hex>
cert	0	CN=OCM Demo Signer	CN=OCM Demo Intermediate CA
cert	1	CN=OCM Demo Intermediate CA	CN=OCM Demo Root CA
```

The digest is the same normalized descriptor digest a plain signature covers; only the encoding of the signature differs.

### What the verifier checks

1. The descriptor digest is recomputed and compared, as for a plain signature. A change to a signed field fails with `digest mismatch`.
2. The signature value is parsed: a `SIGNATURE` block, then the chain, leaf first. A self-signed certificate in the embedded chain is rejected, so a signer cannot supply its own trust anchor.
3. A path is built from the leaf through the embedded intermediates, plus any non-self-signed certificates in the verifier's file, to the self-signed root in the verifier's file. With a root in the file, only that root is trusted. With no self-signed certificate in the file, OCM falls back to the system trust store, so always pin a root.
4. The leaf must be valid now and usable for code signing. A leaf with no extended key usage is accepted.
5. The RSA signature is checked with the leaf's public key.

`ocm sign cv` checks none of steps 2–4. An expired, TLS-only or root-including chain signs successfully and fails only when someone runs `ocm verify cv`.

### Scenarios

`bash scripts/pki.sh scenarios` signs a fresh copy of the component once per row and prints `<scenario> <sign> <verify> <reason>`:

| Scenario | Signer chain | Verifier file | Sign | Verify | Reason |
|---|---|---|---|---|---|
| `valid` | leaf + intermediate | root | ok | ok | — |
| `rotated-leaf` | new key and leaf + intermediate | root (same file) | ok | ok | — |
| `leaf-only-chain` | leaf | root | ok | fail | `unknown-authority` |
| `verifier-supplies-intermediate` | leaf | intermediate + root | ok | ok | — |
| `rogue-root` | leaf + intermediate | another root with the same name | ok | fail | `unknown-authority` |
| `expired-leaf` | leaf valid 2020-01-01 to 2020-01-02 + intermediate | root | ok | fail | `expired` |
| `server-auth-leaf` | leaf with `serverAuth` only + intermediate | root | ok | fail | `key-usage` |
| `root-in-chain` | leaf + intermediate + root | root | ok | fail | `root-embedded` |
| `pinned-public-key` | leaf + intermediate | leaf public key | ok | fail | `not-a-certificate` |
| `intermediate-as-anchor` | leaf + intermediate | intermediate | ok | fail | `unknown-authority` |

`rotated-leaf` is the point of the trust model: the verifier config is byte-for-byte the one used for `valid`. With key pinning, the same rotation needs a new `public.pem` for every consumer. To replace the signature on a component that is already signed, run `ocm sign cv --signature pki --force`; without `--force` OCM fails with `signature "pki" already exists`.

### Own PKI

Set `PKI_LEAF_KEY`, `PKI_CHAIN` (leaf first, then intermediates, no root) and `PKI_ROOT_CERT` together to sign and verify with your own certificates instead of the demo CA. `scripts/pki.sh` refuses a partial set, and `scenarios` always uses the demo CA.

### Transfer

The signature, including the chain, lives in the descriptor, so `ocm transfer cv` carries it and the copy verifies with the same root. See [Transfer and transport](transfer.md#transfer-and-transport).

### Limitations

- Verification checks the leaf against the current time, not the signing time. A signature made while the leaf was valid stops verifying once it expires (`expired-leaf`). RFC 3161 timestamps (`ocm sign cv --tsa` or `--tsa-url`, open-component-model#3636) let verification use a trusted signing time. They are available in OCM 0.21.0; see [trusted timestamps](gpg-signing.md#trusted-timestamps-rfc-3161). On older versions, re-sign before the leaf expires.
- OCM does not check revocation (CRL or OCSP). A revoked leaf verifies until it expires; to distrust a CA, remove it from the verifier's file.
- A PEM signature cannot be verified with a bare public key (`pinned-public-key`); the verifier's file must hold certificates.
- PEM encoding is early access. OCM logs `signing with PEM encoding is experimental` and `verifying signatures with PEM encoding is experimental` as warnings.
- When the verifier's file holds no root, OCM uses the system verifier and its message differs by platform: `certificate signed by unknown authority` on Linux, `certificate is not trusted` on macOS. Both are reported as `unknown-authority`.
