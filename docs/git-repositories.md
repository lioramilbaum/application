# Git repositories

OCM records a Git repository in a component in three ways. A [`Git/v1` input](https://ocm.software/docs/reference/input-and-access-types/#gitv1-input) copies the files of one commit into the component. A [`Git/v1` access](https://ocm.software/docs/reference/input-and-access-types/#gitv1-access) records the repository and a commit, and fetches the files when the resource is downloaded. A source is a `Git/v1` access without a digest.

### Demo component

`components/git/component-constructor.yaml`:

```yaml
name: github.com/lioramilbaum/git-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
sources:
  - name: hello-world-source
    type: git
    version: ${VERSION}
    access:
      type: Git/v1
      repository: ${GIT_DEMO_REPO}
      commit: "${GIT_DEMO_COMMIT}"
resources:
  - name: hello-world-source-snapshot
    type: directoryTree
    version: ${VERSION}
    labels:
      - name: git.lioramilbaum.github.com/commit
        signing: true
        value: "${GIT_DEMO_COMMIT}"
    input:
      type: Git/v1
      repository: ${GIT_DEMO_REPO}
      commit: "${GIT_DEMO_COMMIT}"
  - name: hello-world-source-tracked
    type: directoryTree
    version: ${VERSION}
    access:
      type: Git/v1
      repository: ${GIT_DEMO_REPO}
      ref: ${GIT_DEMO_REF}
```

```sh
make git   # build, sign, verify and audit the Git source demo; offline
```

`make git` creates `build/git/upstream.git` from `components/git/upstream/`: one commit with the tag `v0.1.0`. The repository is created with `--object-format=sha1`, and a fixed identity and date make every run produce the same commit. It writes the component archive to `build/git-ctf`, signs and verifies it, then audits the snapshot against the commit named by its label.

| Record | Constructor form | Stored as | Signed |
|---|---|---|---|
| `hello-world-source` (source) | `access: Git/v1` with `repository` and `commit` | the access only | name, version and type; the access is not |
| `hello-world-source-tracked` (resource) | `access: Git/v1` with `repository` and `ref` | `Git/v1` access, with the ref pinned to a commit at build time | digest; the access is not |
| `hello-world-source-snapshot` (resource) | `input: Git/v1` with `repository` and `commit` | `LocalBlob/v1`, an archive of the tree with media type `application/x-tgz` | digest, and the `git.lioramilbaum.github.com/commit` label, which has `signing: true` |

The source content is recorded without a digest and is not verifiable: OCM never downloads it, so `ocm verify cv` cannot check it, and a changed commit in the source's access goes unnoticed. Declare the artifact as a resource if its content must be checked. The tracked resource is a `Git/v1` access and downloads from the repository at consume time, so it needs the repository and the pinned commit. The snapshot is self-contained: it stores the files, and the signed label names the commit they came from.

### Pinned commits and digests

The `ref` in the tracked resource is resolved to a commit when the component is built. A branch that moves later does not change what the resource downloads (`branch-moved` below). The downloaded archive must match the digest recorded in the descriptor; otherwise the download fails with `git archive digest mismatch`.

The digest covers the tree, not the commit. Two commits with the same tree have the same digest, so the commit named in an access can be replaced with another commit of the same tree without failing a download. A different tree fails with `git archive digest mismatch`.

`bash scripts/git.sh audit` closes the gap for the snapshot. It fetches the commit named by the signed label from the source's repository and compares it with the snapshot files with `diff -r`. It prints `audit <commit> <digest> match`. Without a signature, `audit` stops before it fetches anything.

### Transfer and credentials

`bash scripts/git.sh transfer` runs `ocm transfer cv --copy-resources` and prints the access type of each record in the target. The snapshot becomes a `LocalBlob/v1`, so the copy no longer needs the repository. The tracked resource and the source keep their `Git/v1` access and still need the repository. The signature travels with the copy and still verifies.

A `localblob.uploader.transfer.config.ocm.software/v1alpha1` rule with `match: resource.access.isType("Git")` would copy the tracked resource as well. In OCM 0.19.1 that rule fails with `cannot copy access type Git/v1`; copying `Git/v1` access arrives in v0.20.0-rc.1 (#3709). See [Transfer and transport](transfer.md#transfer-and-transport).

Private repositories are reached with `GitCredentials/v1`, resolved by consumer identity like every other OCM credential. See [Credential system](credentials.md#credential-system).

### Own repository

Set `GIT_DEMO_REPO` and `GIT_DEMO_COMMIT` together to build from a repository you supply instead of the generated one:

```sh
GIT_DEMO_REPO=/path/to/repo GIT_DEMO_COMMIT=<40-char commit SHA> make git
```

Setting only one of them fails. `GIT_DEMO_COMMIT` must be a 40-character SHA-1 commit. A 64-character SHA-256 object name is rejected before the build. OCM 0.19.1 reads SHA-1 repositories only, so a SHA-256 repository fails with `mismatched algorithms` (#3794). `GIT_DEMO_REF` (default `refs/heads/main`) sets the ref that the tracked resource follows at build time. `make git` with your own repository does not create `build/git/upstream.git`. The `scenarios` and `upstream` commands need the generated repository.

### Scenarios

`bash scripts/git.sh scenarios` builds and signs the component once, then changes the generated upstream for each row and prints `<scenario> <verify> <snapshot> <tracked> <reason>`:

| Scenario | Upstream after signing | Verify | Snapshot | Tracked | Reason |
|---|---|---|---|---|---|
| `baseline` | unchanged | ok | ok | ok | - |
| `branch-moved` | `main` has a new commit; the pinned commit is still in the repository | ok | ok | ok | - |
| `history-rewritten` | `main` is force-pushed and the pinned commit is removed | ok | ok | fail | `missing-commit` |
| `upstream-deleted` | the repository is deleted | ok | ok | fail | `repository-not-found` |

The snapshot is a `LocalBlob/v1` in the component, so it downloads in every row. The tracked resource needs the pinned commit, so it fails once the commit is removed or the repository is gone. Verification passes in every row because the component is not changed.

### Limitations

- `make git` needs OCM CLI ≥ 0.19.0 (`Git/v1` input and access) and `git` 2.32 or newer. The script refuses to run with an older OCM CLI.
- The demo uses `file://` repositories only. Remote repositories need `GitCredentials/v1` for private ones.
- The source is not verifiable, and its commit is not signed. The snapshot's label is the only signed link to a commit.
- `srcRefs` is not signed and this component does not use it.
- Copying `Git/v1` access in a transfer arrives in v0.20.0-rc.1 (#3709).

Related: [Source provenance](architecture.md#source-provenance) · [Signing and verification](signing.md#signing-and-verification) · [Transfer and transport](transfer.md#transfer-and-transport) · [Credential system](credentials.md#credential-system)
