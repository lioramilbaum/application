# HTTP resources

A resource can be fetched over HTTP. OCM's `Wget/v1` type has two forms: as an `input:` it downloads the bytes at build time and stores them as a `LocalBlob/v1`; as an `access:` it records the URL and a pinned digest, and fetches the bytes when the resource is downloaded. `HTTP/v1` is an alias for the same type. Access types are listed in [Resource repositories](repositories.md#resource-repositories).

### Demo component

`components/wget/component-constructor.yaml`:

```yaml
name: github.com/lioramilbaum/wget-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: release-notes
    type: blob
    version: ${VERSION}
    input:
      type: Wget/v1
      url: ${WGET_DEMO_URL}/release-notes.txt
      mediaType: text/plain
  - name: hello-world-page
    type: blob
    version: ${VERSION}
    relation: external
    digest:
      hashAlgorithm: SHA-256
      normalisationAlgorithm: genericBlobDigest/v1
      value: "c0bbf62451fea3d4cd065e104995118b3c9861473d4f5cffed42203d650f76f4"
    access:
      type: Wget/v1
      url: ${WGET_DEMO_URL}/index.html
      mediaType: text/html
```

```sh
make wget   # build, sign, verify and download against a local upstream server; offline apart from 127.0.0.1
```

`make wget` starts `scripts/upstream-server.py` on `127.0.0.1:18431` (override with `WGET_DEMO_PORT`), writes the component archive to `build/wget-ctf` and the downloaded files to `build/wget/download/`.

### Input or access

| Form | Stored as | When the bytes are fetched | Integrity |
|---|---|---|---|
| `input: type: Wget/v1` | `LocalBlob/v1`, relation `local` | build time (`ocm add cv`) | digest computed from the fetched bytes, subject to the checksum mode |
| `access: type: Wget/v1` | `Wget/v1`, relation `external` | download time (`ocm download resource`) | digest pinned in the descriptor; a changed upstream fails with `digest mismatch` |

An `input:` is copied into the component, so later changes upstream do not affect it. An `access:` is only a reference: consumers need the server at download time, and the pinned digest is what keeps them from receiving different bytes.

### Checksums

OCM reads the `checksum.http.config.ocm.software/v1alpha1` configuration to decide what to do with a `Content-Digest` header (RFC 9530) sent by the server:

| Mode | Behaviour |
|---|---|
| `Require` | fails when the server advertises no checksum (`no advertised checksum`) |
| `Prefer` | uses the advertised checksum when present, otherwise the pinned digest |
| `Skip` | ignores the advertised checksum |

`make wget` writes the mode from `WGET_DEMO_CHECKSUM_MODE` (`Require`, `Prefer` or `Skip`, default `Prefer`) to `build/wget/checksum.ocmconfig`. `WGET_DEMO_DIGEST` (`none`, `sha-256`, `sha-512` or `wrong`) selects which header the demo server sends. For the pinned digest, only SHA-256 is supported; the download check in `scripts/wget.sh` compares SHA-256 digests only.

`bash scripts/wget.sh checksum` runs a matrix of header and mode combinations and prints one row per combination: the header, the mode, `ok` with the advertised algorithm, or `fail` with a reason.

### Credentials

A server that requires authentication is reached with `WgetCredentials/v1` (`username`, `password`). The credential is selected by the URL, using a consumer with identity `type: Wget` and `hostname`, `port` and `scheme`. Credentials are configured the same way as other OCM credentials; see [Credential system](credentials.md#credential-system).

### Transfer

`components/wget/transfer.ocmconfig` holds a `localblob.uploader.transfer.config.ocm.software/v1alpha1` rule that matches `resource.access.isType("Wget")`. With it, `ocm transfer cv` fetches the page and stores it as a `LocalBlob/v1` in the target, so the target no longer needs the upstream. Without it, the target keeps the `Wget/v1` access and still needs the upstream at download time. The copy checks the fetched bytes against the pinned digest. See [Transfer and transport](transfer.md#transfer-and-transport).

`bash scripts/wget.sh transfer` prints the access type of each resource in both target repositories.

### Signing

The component is signed like any other. A signature covers the descriptor, which includes the pinned digest, so changing that digest breaks verification. See [Signing and verification](signing.md#signing-and-verification).

### Limitations

- `make wget` needs OCM CLI ≥ 0.19.0. Earlier releases ignore `checksum.http.config` and download changed bytes without an error; the script refuses to run with them. The checksum handling was fixed upstream in #3889.
- Only SHA-256 is supported for the pinned digest.
- The demo upstream listens on `127.0.0.1` only and needs `python3`.
