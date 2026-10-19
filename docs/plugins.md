# Plugin system

The [OCM plugin system](https://ocm.software/docs/concepts/plugin-system/) adds repository
types, access types, input types, credential backends, and signing handlers to OCM without
forking it. A plugin is a standalone binary, usually built with the Go SDK in
[`bindings/go/plugin`](https://github.com/open-component-model/open-component-model/tree/main/bindings/go/plugin).
The `ocm` CLI scans one directory, `--plugin-directory` (default `$HOME/.config/ocm/plugins`),
runs each binary with `capabilities` to learn which types it serves, and starts it only when a
command needs one of them. Requests are HTTP + JSON over a Unix domain socket (or TCP in scratch containers), and the
plugin exits after an idle timeout. Plugin discovery settings go in `.ocmconfig` under `plugin.config.ocm.software/v2alpha1`: `idleTimeout` (default one hour) is honored, but `locations` is always overwritten by `--plugin-directory`, which has a default value (see Limitations below).

Every type this component uses is served by a built-in plugin compiled into `ocm`, so build,
sign, verify, and transfer need no plugin installed:

| Type in this component | Built-in plugin |
|---|---|
| `CommonTransportFormat/v1` (`ctf::`), `OCIRepository/v1` (`oci::`), `OCIImage/v1`, `LocalBlob/v1` | OCI |
| `file` and `Dir/v1` inputs | file, dir |
| `GitHub/v1` source access | GitHub |
| `RSA/v1alpha1` signatures | RSA |

An external plugin fits when an artifact lives where OCM cannot reach it. If the manifests sat
in an internal artifact store, a resource repository plugin for that store's access type would
let `component-constructor.yaml` reference them with `access:` while `make build`,
`ocm download resource`, and `make publish` stay unchanged. Plugins are shipped as OCM
component versions, so `ocm download plugin` fetches a plugin binary from one into the plugin
directory.

### Demo component

`components/plugin/component-constructor.yaml`:

```yaml
name: github.com/lioramilbaum/plugin-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: demo-blob
    type: blob
    version: ${VERSION}
    access:
      type: demo-store/v1alpha1
      storeId: my-store
      blobId: blob-001
```

```sh
make plugin   # install the plugin, build, download through it and show its capabilities; offline
```

The `demo-blob` resource has no `input:`. Its bytes live in a store that only the plugin can read, and OCM records the digest the plugin reports when the component is built. `make plugin` copies the plugin and its store into `build/plugins/`, writes the component archive to `build/plugin-ctf`, and downloads the blob to `build/plugin/download/demo-blob`:

```text
build/
├── plugins/                    # --plugin-directory
│   ├── demo-store-plugin       # the plugin executable
│   └── demo-store.json         # the store it serves; ignored by OCM (no extensionless name)
├── plugin-ctf/                 # the component archive
└── plugin/
    ├── credentials.ocmconfig   # Credentials/v1 for demo-store/v1alpha1, storeId my-store
    └── download/demo-blob      # the downloaded bytes
```

### Wire protocol

The demo plugin (`components/plugin/demo-store/demo-store-plugin`) speaks the 0.19.1 protocol:

- `demo-store-plugin capabilities` prints one JSON object. Its `capabilities` array has one entry per plugin type, `resourceRepository` and `digestProcessorRepository`. Each lists its `supportedAccessTypes`, and each access type has `type`, `aliases` and `jsonSchema`, a base64-encoded JSON Schema of the access spec. OCM runs `capabilities` on every plugin in the directory before every command.
- `demo-store-plugin --config '{"id":"demo-store-plugin","type":"unix","idleTimeout":3600000000000}'` starts server mode. `idleTimeout` is in nanoseconds. The plugin creates a Unix socket and prints `http+unix://<path>` to stdout with `flush=True`. That line must be the only thing written to stdout.
- Endpoints, all with JSON bodies except `/healthz`:
  - `GET /healthz` returns `{"status":"ok"}`.
  - `POST /identity` takes `{"type": <access spec>}` and returns `{"identity":{"type":"demo-store/v1alpha1","storeId":"my-store"}}`. OCM matches credential consumers against this identity.
  - `POST /resource/get` takes `{"resource": {...}}` and returns a location, for example `{"location":{"type":"localFile","value":"<path>","mediaType":"text/plain"}}`. OCM reads the file at `value`.
  - `POST /resource/digest/process` takes `{"resource": {...}}` and returns the same resource with a `digest` (`hashAlgorithm`, `normalisationAlgorithm`, `value`).
- Credentials for `/resource/get` and `/resource/digest/process` arrive in the `Authorization` header as the JSON of the resolved credential object, for example `{"type":"Credentials/v1","properties":{"token":"demo-token"}}`. The demo also accepts `Bearer` and `Basic` headers.
- Anything the plugin writes to stderr is forwarded into OCM's log. The demo writes JSON lines, which appear with `--loglevel debug`.
- SIGINT or SIGTERM shuts the server down. The plugin also exits when its parent (OCM) exits, or after its idle timeout with no requests.

### Registering a plugin

Pass the directory with `--plugin-directory <dir>`. The default is `$HOME/.config/ocm/plugins`.

- Every extensionless file in the directory is a plugin. A non-executable one fails with `fork/exec` on every command. Files with an extension, such as `demo-store.json`, are ignored.
- A symlink to a directory is discovered and exec'd, which fails with `permission denied`. Put the plugin binaries directly in the directory.
- `capabilities` runs for every plugin on every `ocm` command, including `ocm version`. One plugin whose `capabilities` output does not parse (`failed to unmarshal capabilities`) breaks every command, not only the ones that use its types.

### Writing a plugin in Python

The demo plugin is stdlib only and runs on Python 3.9. These points cost the most debugging time:

- Flush the socket line. Stdout is block-buffered when it is a pipe, so `print(...)` without `flush=True` never reaches OCM.
- Unix socket peers have no address: `client_address` is `''`. `BaseHTTPRequestHandler.address_string()` indexes into it and raises `IndexError`. Override `address_string`, and pass a placeholder address from `get_request`.
- Keep the socket path short. Unix socket paths are limited to 104 bytes on macOS, and `TMPDIR` there is a long `/var/folders/...` path. Create the socket directory with `tempfile.mkdtemp(dir="/tmp")`.
- Log to stderr at DEBUG as JSON lines. OCM forwards them and shows them with `--loglevel debug`.
- Clean up on SIGINT and SIGTERM. Remove the socket directory and any blob files in a `finally`. Call `server.shutdown()` from another thread: it blocks until `serve_forever()` returns, so calling it on the serving thread, including from a signal handler, deadlocks.
- Watch the parent. Poll `os.getppid()` and exit when it changes. Without this, a plugin whose OCM was killed stays alive until its idle timeout, one hour by default.

### Scenarios

`bash scripts/plugin.sh scenarios [name...]` runs the demo against the failure modes OCM reports. Each row is `<scenario> <ocm> <check> <reason>`: `ocm` is the `ocm download` or `ocm add cv` result, `check` is the script's own digest comparison of the downloaded file, and `reason` is the failure classified from OCM's stderr.

| Scenario | Reason |
|---|---|
| `correct` | `-` |
| `missing-plugin` | `no-plugin` |
| `config-locations` | `no-plugin` |
| `malformed-capabilities` | `bad-capabilities` |
| `malformed-response` | `malformed-response` |
| `plugin-error` | `plugin-error` |
| `unsupported-location` | `unsupported-location` |
| `unknown-blob` | `not-found` |
| `invalid-spec` | `invalid-spec` |
| `no-credentials` | `unauthorized` |
| `tampered-content` | `digest-mismatch` |

### Limitations

- OCM 0.19.1 does not check the bytes served by `/resource/get` against the digest in the descriptor, so a plugin that serves tampered bytes downloads "successfully". `make plugin` catches this with its own comparison (`tampered-content`).
- `ocm describe types access` lists only built-in access types, not plugin types.
- There is no `ocm plugin list`. `ocm plugin` only has `registry` subcommands. To see what is registered, run with `--loglevel debug` and read the `discovered plugin` and `adding ... plugin` lines.
- `locations` under `plugin.config.ocm.software` is always overwritten by `--plugin-directory`, which always has a value, so it never takes effect.
