# application

A minimal HelloWorld application built with the [Open Component Model](https://ocm.software) (OCM v2), deployed on a kind cluster.

The repository also contains demos for individual OCM concepts (component graphs, GitHub access, signing normalisation, S3 resources, and resources without access). Each has a `make` target and a documentation page under [`docs/`](docs/).

## Quick start

The `.devcontainer/` directory provides all required tools when used with Docker Desktop or a compatible Docker host and devcontainers CLI.

```bash
make build     # build the OCM component archive (CTF)
make sign      # sign it with an auto-generated dev key
make verify    # verify the signature
make deploy    # deploy the application to the current cluster (requires KUBECONFIG)
make test      # run the test suite
make lint      # lint shell scripts
```

`make e2e` creates a kind cluster, deploys the application, checks that the pod is ready, and tears the cluster down. It requires Docker. The full list of targets is in `make help`, and the prerequisites for each demo are in [Prerequisites](docs/development.md#prerequisites).

## Documentation

### Concepts

- [Architecture](docs/architecture.md): component tree, deploy-time configuration, component identity, localization, and source provenance
- [Credential system](docs/credentials.md): consumer identities and credential matching
- [Repositories](docs/repositories.md): resolvers, resource repositories, and canonical component repositories
- [Transfer and consumption](docs/transfer.md): transfer and transport, and consuming the component
- [Kubernetes](docs/kubernetes.md): controller, deployer, and component discovery
- [Controller stack](docs/controller.md): OCM controllers, kro and Flux; make controller
- [Plugin system](docs/plugins.md): external plugins and the demo-store plugin

### Signing

- [Signing](docs/signing.md): signing and verification, signing normalisation, real signing keys, and keyless signing (Sigstore)
- [Certificate-chain signing](docs/certificate-chain-signing.md)
- [GPG signing](docs/gpg-signing.md)

### Components and graphs

- [Ownership and SBOMs](docs/ownership-and-sbom.md): ownership records and software bills of materials
- [Component graphs](docs/component-graphs.md): component references, graphs, and version selection

### Resource types

- [Helm charts](docs/helm-charts.md)
- [HTTP resources](docs/http-resources.md)
- [Git repositories](docs/git-repositories.md)
- [GitHub access](docs/github-access.md)
- [OCI images](docs/oci-images.md)
- [Local OCI registry](docs/local-oci-registry.md)
- [S3 resources](docs/s3-resources.md)
- [Resources without access (None)](docs/none-access.md)

### Development

- [Development](docs/development.md): prerequisites, lifecycle, end-to-end testing, running tests, CI, version management, and notes
