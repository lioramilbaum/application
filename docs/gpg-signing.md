# GPG signing

OCM can sign a component with an OpenPGP key. The signature is a detached OpenPGP signature over the same normalized descriptor digest that the RSA signature covers. It is stored under the name `gpg` and selected with the consumer identity `GPG/v1alpha1` and the credential type `GPGCredentials/v1alpha1`. The [OCM GPG tutorial](https://ocm.software/docs/tutorials/signing/gpg/) describes the model; this demo runs it offline with keys generated for the run.

### Demo component

`components/gpg/component-constructor.yaml`:

```yaml
name: github.com/lioramilbaum/gpg-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: release-notes
    type: blob
    version: ${VERSION}
    input:
      type: utf8
      text: "github.com/lioramilbaum/gpg-demo ${VERSION}"
```

```sh
make gpg   # create the demo keys, build, sign, verify and download; offline
```

`make gpg` writes the component archive to `build/gpg-ctf` and the keys and configs to `build/gpg/`.

### Keys

The demo key is RSA 3072 and has two parts:

- a primary key `[C]` that certifies the signing subkey; the configs name its fingerprint, written to `build/gpg/keys/signer.fpr`
- a signing subkey `[S]`; OCM signs with it automatically

Both are valid for two years. `build/gpg/keys/signer.sec.asc` is mode 0600, and `signer.pub.asc` holds the public key. The keys are created in a throwaway `GNUPGHOME` under `/tmp` (not `$TMPDIR`, whose path is too long for gpg-agent sockets on macOS) and the directory is removed on exit. `~/.gnupg` is never read or written. The keys have no passphrase. They are reused across runs and regenerated when the signing subkey expires within a day.

### Configuration

The signer config (`build/gpg/sign.ocmconfig`) holds the key files and the fingerprint to sign with:

```yaml
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: GPG/v1alpha1
          signature: gpg
        credentials:
          - type: GPGCredentials/v1alpha1
            privateKeyPGPFile: /abs/path/build/gpg/keys/signer.sec.asc
            publicKeyPGPFile: /abs/path/build/gpg/keys/signer.pub.asc
  - type: signing.config.ocm.software/v1alpha1
    signer:
      type: GPGSigningConfiguration/v1alpha1
      signature: gpg
      keyFingerprint: <primary fingerprint from build/gpg/keys/signer.fpr>
```

The verifier config (`build/gpg/verify.ocmconfig`) holds only the public key and a verifier:

```yaml
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: GPG/v1alpha1
          signature: gpg
        credentials:
          - type: GPGCredentials/v1alpha1
            publicKeyPGPFile: /abs/path/build/gpg/keys/signer.pub.asc
  - type: signing.config.ocm.software/v1alpha1
    verifier:
      type: GPGSigningConfiguration/v1alpha1
      signature: gpg
```

GPG must be selected explicitly. Unlike RSA, OCM has no default GPG verifier: a verify config without the `verifier` entry fails with `media-type` (the `default-verifier` scenario below).

`bash scripts/gpg.sh show` prints the stored signature, the key that made it, and the subkey that signed:

```text
signature	gpg	GPG	application/vnd.ocm.signature.gpg
digest	jsonNormalisation/v4alpha1	SHA-256	<hex>
key	<primary fingerprint>	OCM Demo Signer <signer@gpg-demo.lioramilbaum.github.com>
signed-by	<signing subkey fingerprint>	SHA-256
```

### What the signature covers

The signature covers the same descriptor digest as the RSA signature: `jsonNormalisation/v4alpha1` over the descriptor, hashed with SHA-256. The `hashAlgorithm` in the signer config changes only the OpenPGP hash applied to that digest. The OCM digest does not change. The `sha512-signature` scenario signs with `hashAlgorithm: SHA-512`; its digest is identical to the default one, and `show` reports `SHA-512` in `signed-by`.

### Cross-check with gpg

`bash scripts/gpg.sh crosscheck` takes the signature and the digest from the descriptor and runs stock `gpg --verify` on them:

```text
crosscheck	good	<signing subkey fingerprint>	<primary fingerprint>
```

Stock `gpg` accepts the signature over the recorded digest, but it does not apply OCM's normalization, so it cannot recompute the digest from the descriptor. A descriptor edited after signing still passes `crosscheck`. `ocm verify cv` rejects it with `digest mismatch`. Use `ocm verify` as the authority; `crosscheck` only shows that the signature is a valid OpenPGP signature over the recorded digest.

### Several signatures

`bash scripts/gpg.sh multi` signs a copy of the component with the RSA `default` key and with the GPG key, then prints both signatures. Both cover the same digest:

```text
signature	default	RSASSA-PSS	application/vnd.ocm.signature.rsa.pss	<digest>
signature	gpg	GPG	application/vnd.ocm.signature.gpg	<digest>
```

To verify only the GPG signature, pass `--signature gpg`. OCM 0.19.1 applies every configured verifier to every signature when no `--signature` flag is given, and the `signature:` field of a verifier entry does not limit that. The GPG verifier therefore fails on the RSA signature with `unsupported media type`.

### Scenarios

`bash scripts/gpg.sh scenarios` signs a fresh copy of the component once per row and prints `<scenario> <sign> <verify> <reason>`:

| Scenario | Signing key | Verifier | Sign | Verify | Reason |
|---|---|---|---|---|---|
| `valid` | signer key | signer public key | ok | ok | - |
| `rotated-key` | second valid key | keyring with signer and second key | ok | ok | - |
| `concatenated-keyring` | second key | signer and second public keys concatenated | ok | ok | - |
| `wrong-key` | key not in the verifier | signer public key | ok | fail | `unknown-key` |
| `verifier-pins-other-key` | signer key | keyring, pinned to the second key's fingerprint | ok | fail | `error` |
| `pinned-subkey` | signing subkey as `keyFingerprint` | signer public key | ok | ok | - |
| `expired-key` | key that expired in 2020 | its public key | fail | - | `error` |
| `expired-after-signing` | key without expiry at signing time; expiry set later | its public key | ok | fail | `key-expired` |
| `revoked-key` | key revoked after export | its public key | ok | fail | `revoked` |
| `protected-key` | passphrase-protected key, `passphrase: secret` | its public key | ok | ok | - |
| `protected-key-no-passphrase` | same key, no passphrase | its public key | fail | - | `passphrase-required` |
| `sha512-signature` | signer key, `hashAlgorithm: SHA-512` | signer public key | ok | ok | - |
| `default-verifier` | signer key | GPG credentials without a `verifier` entry | ok | fail | `media-type` |

The `concatenated-keyring` row shows that a full keyring (all keys readable) verifies in OCM 0.21.0. `pinned-subkey` works in OCM ≥ v0.21.0-rc.1 (#3858), which added support for pinning signing subkey fingerprints. OCM 0.21.0 (#3691) changed GPG signing to invoke the system `gpg` binary instead of a pure-Go implementation; the `default-verifier` scenario fails with `media-type` because a credentials-only GPG entry no longer acts as a catch-all verifier.

### Own keys

Set `GPG_PRIVATE_KEY` and `GPG_PUBLIC_KEY` together to sign with your own armored secret and public key files instead of the generated ones:

```sh
GPG_PRIVATE_KEY=/path/to/signer.sec.asc GPG_PUBLIC_KEY=/path/to/signer.pub.asc make gpg
```

Setting only one of them fails. The primary fingerprint is read from the secret key file. `scenarios` needs the generated demo keys and refuses to run with your own.

### Transfer

The signature is stored in the descriptor, so `ocm transfer cv` carries it to the target, and the copy verifies with the same `verify.ocmconfig`. See [Transfer and transport](transfer.md#transfer-and-transport).

### Limitations

- Expiry and revocation are checked at verify time, not at signing time. A signature made while the key was valid fails once it expires (`expired-after-signing`) or is revoked (`revoked-key`).
- A concatenated armored file loads only its first key (`concatenated-keyring`).
- Pinning a signing subkey fingerprint (`pinned-subkey`) requires OCM ≥ v0.21.0-rc.1 (#3858).
- When no more specific reason is classifiable, the reason is `error`; this is a catch-all for unrecognised OCM error messages.
- A passphrase-protected key needs `passphrase` in the credentials of the signer config. Without it, signing fails with `passphrase-required`.

Related: [Signing and verification](signing.md#signing-and-verification) · [Certificate-chain signing](certificate-chain-signing.md#certificate-chain-signing) · [Transfer and transport](transfer.md#transfer-and-transport) · [Credential system](credentials.md#credential-system)
