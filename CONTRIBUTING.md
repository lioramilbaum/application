# Contributing

## Prerequisites

The recommended way to contribute is to open the repository in the provided devcontainer (`.devcontainer/`). It requires Docker Desktop or a compatible Docker host and the [devcontainers CLI](https://github.com/devcontainers/cli):

```sh
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . make lint test
```

The devcontainer provides ocm, kind, flux, kubectl, helm, shellcheck, jq, python3 and openssl. CI uses the same image, so local results match CI exactly.

Outside the devcontainer, see [Prerequisites](docs/development.md#prerequisites) for the full tool list and version requirements.

## Getting the code

Fork `lioramilbaum/application`, clone your fork, and add the upstream remote:

```sh
git clone git@github.com:<your-user>/application.git
cd application
git remote add upstream git@github.com:lioramilbaum/application.git
```

Sync before starting work:

```sh
git fetch upstream && git checkout main && git merge --ff-only upstream/main
```

## Branch naming

Create a `feat/<name>` branch from an up-to-date `main`, using a short kebab-case name:

```sh
git switch -c feat/my-change
```

Examples: `feat/gpg-signing`, `feat/split-readme-into-docs`. Never commit directly to `main`.

## Running lint and tests

```sh
make lint   # shellcheck on scripts/*.sh and test/run.sh
make test   # bash test/run.sh — must report 0 failed
```

Tests exit 77 to report SKIP (for example when Docker is unavailable). `make e2e` runs the full end-to-end test and needs Docker and internet access. Docker Hub access (`nginx:1.31-alpine`) is required for `make test`.

New behaviour needs a test in `test/run.sh`: a `test_*` function plus a `run_test` line that fails without the change. List new test names in [Running tests](docs/development.md#running-tests).

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `test:`, `chore:`, or `ci:` prefix, imperative subject, optional bullet body.

One commit per PR. Squash before pushing:

```sh
git reset --soft $(git merge-base HEAD upstream/main)
git commit -m "feat: my change"
git push --force-with-lease origin feat/my-change
```

When Claude Code helped, end the commit message with:

```
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

Use the model that did the work (substitute the actual model used, e.g. `Haiku 5.5` or `Opus 5.5`).

## Opening a pull request

Push to your fork and open a draft PR against upstream `main`:

```sh
git push -u origin feat/my-change
gh pr create --draft --repo lioramilbaum/application --base main \
  --head <your-user>:feat/my-change
```

The PR body should have `## Summary` and `## How to test` sections, including the `make test` result counts. Mark it ready for review once CI (`ci.yaml`, `e2e.yaml`) is green.

Do not push commits onto Renovate PRs or onto already-merged PRs — open a new PR instead.

## License

By contributing you agree that your contributions are licensed under [Apache 2.0](LICENSE), per section 5 of the license.
