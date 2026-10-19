# GitHub access

`GitHub/v1` is an OCM access type that records a commit of a GitHub repository and downloads that commit's archive through the GitHub REST API. The access stores `repoUrl` and `ref`; the ref is resolved to a `commit` when the component is built, and the download fetches the tarball of that commit. The downloaded bytes must match the digest in the descriptor. `GitHub/v1` is for commit archives, not release assets: a file attached to a GitHub release is a plain HTTP download and uses `Wget/v1` (see [HTTP resources](http-resources.md#http-resources)).

`GitHub/v1` is deprecated in favour of `Git/v1`, which records a repository and a commit in the same way and reads the repository directly instead of the REST API. See [Git repositories](git-repositories.md#git-repositories). This demo keeps `GitHub/v1` because its access and digest check are still in use.

### Demo component

`components/github/component-constructor.yaml`:

```yaml
name: github.com/lioramilbaum/github-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: hello-world-repo-archive
    type: blob
    version: ${VERSION}
    relation: external
    access:
      type: GitHub/v1
      repoUrl: "${GITHUB_DEMO_REPO_URL}"
      ref: refs/heads/main
```

```sh
make github   # build, sign, verify, download and transfer the GitHub/v1 demo; offline
```

OCM treats a `repoUrl` whose host is not `github.com` as GitHub Enterprise and sends its requests to `{host}/api/v3/`. `make github` starts `scripts/github-api-server.py` on `127.0.0.1:18451` and serves the endpoints OCM calls:

| Endpoint | Response |
|---|---|
| `GET /api/v3/repos/{owner}/{repo}/commits/{ref}` | The commit SHA as plain text with `Accept: application/vnd.github.v3.sha`, `{"sha": ...}` otherwise; `404` for an unknown ref |
| `GET /api/v3/repos/{owner}/{repo}/tarball/{sha}` | `302` to `/_codeload/{owner}/{repo}/{sha}.tar.gz` |
| `GET /_codeload/{owner}/{repo}/{sha}.tar.gz` | The archive of the commit |
| `GET /-/ready`, `GET /-/log` | Readiness, and the requests received so far |

The archive is built in memory with fixed modification times, owner and group, and sorted entries, under a top directory named `{owner}-{repo}-{sha[:7]}/`. The same tree therefore always gives the same digest. The tree is `components/github/upstream/`.

Running `bash scripts/github.sh scenarios` prints one row per scenario, `<scenario> <result> <detail>`:

| Scenario | What changes | Result |
|---|---|---|
| `pinned` | nothing | `ok`, with the digest of the archive |
| `branch-moved` | `refs/heads/main` points at another commit | `pinned-commit-kept`: the download requests the commit recorded at build time |
| `archive-rewritten` | the emulator adds an entry to the archive of the pinned commit, as if GitHub had regenerated it | `digest-mismatch`: the download is rejected |
| `api-down` | the emulator is stopped | `connection-refused`: the access needs the API when it is consumed |
| `copied` | `ocm transfer cv` with `components/github/transfer.ocmconfig` | `LocalBlob/v1`: the archive is inlined and no longer needs the API |

The access keeps the commit from build time, so moving the branch does not change what is downloaded. The digest is checked against the bytes, not the commit, so a rewritten archive for the same commit fails. A rejected download leaves the file at `--output`; `scripts/github.sh` deletes it after the check.

### Online mode

`GITHUB_DEMO_ONLINE=1 bash scripts/github.sh online` builds `build/github/online-ctf` from `components/github/online-constructor.yaml`. The constructor has two resources: the `open-component-model/ocm-examples` repository at a fixed commit (`GitHub/v1`), and the `chart-0.19.1.tgz` release asset of `open-component-model` (`Wget/v1`, see [HTTP resources](http-resources.md#http-resources)). The script downloads both from github.com, prints the top directory of the archive, and checks that the chart starts with the gzip magic bytes. It needs network access. Without `GITHUB_DEMO_ONLINE=1` it prints `skip:` and exits 0.

### Limitations

- S3/v1 and S3/v2 access is covered in [S3 resources](s3-resources.md#s3-resources).
- The emulator serves only the `GitHub/v1` endpoints listed above. Authentication with `GitHubCredentials/v1` is not exercised offline.
- `make github` needs `python3` and `curl`. The emulator binds `127.0.0.1` only.

Related: [Git repositories](git-repositories.md#git-repositories) · [HTTP resources](http-resources.md#http-resources) · [Credential system](credentials.md#credential-system)
