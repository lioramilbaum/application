# S3 resources

`S3/v1` and `S3/v2` are OCM access types for objects in an S3-compatible bucket. The access records where the object lives, and OCM downloads it with the credentials of a matching consumer identity. `S3/v1` names the object with `bucket` and `key`. `S3/v2` names it with `bucketName` and `objectKey`, and can pin the object to a version with `version`.

This demo runs `rustfs/rustfs`, an S3-compatible server; MinIO was replaced because its community Docker images were removed in October 2025. The image is pinned by digest in `scripts/s3.sh`. The demo needs Docker and `curl` 7.75 or newer, because it signs its requests with `--aws-sigv4`. Without a Docker daemon the script prints `skip:` and exits 0.

The AWS SDK falls back to the default credential chain (environment variables, `~/.aws`, instance metadata) when no consumer identity matches. `scripts/s3.sh` points `AWS_SHARED_CREDENTIALS_FILE` and `AWS_CONFIG_FILE` at `/dev/null`, unsets the `AWS_*` variables and disables the metadata endpoint. Without that, a missing consumer entry would silently use your own AWS account.

### Demo component

`components/s3/component-constructor.yaml`:

```yaml
name: github.com/lioramilbaum/s3-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: notes-v1
    type: plainText
    version: ${VERSION}
    relation: external
    access:
      type: S3/v1
      bucket: ocm-demo
      key: releases/notes.txt
      region: us-east-1
      endpoint: "${S3_DEMO_ENDPOINT}"
      usePathStyle: true
    mediaType: text/plain
  - name: notes
    type: plainText
    version: ${VERSION}
    relation: external
    access:
      type: S3/v2
      bucketName: ocm-demo
      objectKey: releases/notes.txt
      region: us-east-1
      endpoint: "${S3_DEMO_ENDPOINT}"
      usePathStyle: true
    mediaType: text/plain
  - name: notes-pinned
    type: plainText
    version: ${VERSION}
    relation: external
    access:
      type: S3/v2
      bucketName: ocm-demo-versioned
      objectKey: releases/notes.txt
      region: us-east-1
      endpoint: "${S3_DEMO_ENDPOINT}"
      usePathStyle: true
    mediaType: text/plain
  - name: notes-input
    type: plainText
    version: ${VERSION}
    input:
      type: S3/v2
      bucketName: ocm-demo
      objectKey: releases/notes.txt
      region: us-east-1
      endpoint: "${S3_DEMO_ENDPOINT}"
      usePathStyle: true
      mediaType: text/plain
```

```sh
make s3   # start the server, seed the buckets, build, sign, verify, download and run the scenarios; offline except for the local server
bash scripts/s3.sh stop   # remove the container
```

`notes`, `notes-v1` and `notes-pinned` are `relation: external`: the bytes stay in the bucket and the component records only the access. `notes-input` is an `input`: `ocm add cv` reads the object once and stores it as a `LocalBlob/v1`.

### Credentials

The consumer identity of an S3 access is `bucketName/objectKey` (for `S3/v1`, `bucket/key`) on the endpoint host. The credential entry must match it:

| Field | Value in this demo | Meaning |
|---|---|---|
| `type` | `S3` | Identity type; the credential type is `S3Credentials/v1` |
| `scheme` | `http` | Compared only when the entry sets it |
| `hostname` | `127.0.0.1` | Must be equal; there are no hostname wildcards |
| `port` | `"19000"` | Quoted string |
| `path` | optional, for example `ocm-demo/releases/*` | `path.Match` pattern on `bucket/key`; `*` stays within one segment |

Credentials are the top-level fields `accessKeyId` and `secretAccessKey` of `S3Credentials/v1`. `path: ocm-demo/**` matches across segments only in OCM 0.21.0 and later (#3746); in OCM 0.19.1 it does not match, so use one `*` per segment there.

### Object versioning

An S3 object has no digest in its descriptor unless OCM computes one at build time. The bucket decides what the access can pin:

- In an unversioned bucket (`ocm-demo`), `ocm add cv` warns that the object `carries no version`. A later overwrite of the object changes what the access resolves to, and the digest check then fails.
- In a versioned bucket (`ocm-demo-versioned`), the build records the `x-amz-version-id` of the object in the access (`version`). Overwrites create new versions, and the pinned version keeps its bytes.

### Input vs access

`notes-input` embeds the bytes at build time, so the component carries them as a `LocalBlob/v1`. The other three resources depend on the server at consume time. Changing the object afterwards does not affect `notes-input`, and the signed digest covers the bytes that were read at build time.

### Scenarios

`bash scripts/s3.sh scenarios` prints one row per scenario, `<scenario> <resource> <result>`:

| Scenario | What changes | Result |
|---|---|---|
| `pinned` | nothing | `ok` for `notes` and `notes-v1` |
| `overwritten` | the object in `ocm-demo` is replaced | `digest-mismatch` for `notes` and `notes-v1` |
| `overwritten-versioned` | the object in `ocm-demo-versioned` is replaced | `ok` for `notes-pinned`: the pinned version keeps its bytes |
| `overwritten-input` | the object in `ocm-demo` is replaced | `ok` for `notes-input`: the embedded bytes are not fetched |
| `no-credentials` | the config has no consumer entry | `credentials-missing` |
| `glob-star` | consumer `path: ocm-demo/releases/*` | `ok` |
| `glob-doublestar` | consumer `path: ocm-demo/**` | `ok` (\*\* crosses / since OCM 0.21.0, #3746) |
| `copied-v2` | `ocm transfer cv --copy-resources` | `LocalBlob/v1` for `notes` |
| `copied-v1` | the same transfer | `S3/v1` for `notes-v1` (the transfer leaves it as it is) |
| `server-down` | the container is stopped | `connection-refused` for `notes`; `ok` for `notes-input` |

### Transfer

`ocm transfer cv --copy-resources` downloads the `S3/v2` resources and stores them as `LocalBlob/v1`, so the target no longer needs the bucket. In OCM 0.19.1 the `S3/v1` access is kept as it is, so `notes-v1` still needs the bucket after the transfer.

### Limitations

- `make s3` needs Docker, and the container's data is lost on `stop`.
- `make s3` needs `curl` 7.75 or newer for `--aws-sigv4`.
- The demo does not exercise STS or temporary credentials.

Related: [Credential system](credentials.md#credential-system) · [Resource repositories](repositories.md#resource-repositories) · [Local OCI registry](local-oci-registry.md#local-oci-registry)
