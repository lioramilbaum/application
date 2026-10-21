# Controller stack

The controller stack runs the application without `make deploy`. The cluster pulls the published component from `ghcr.io/lioramilbaum/ocm`, and three controllers do the work:

- the [OCM controllers](https://ocm.software/docs/getting-started/set-up-controller-environments/) resolve the component and the resources, and apply the `NamespacedDeployer`;
- [kro](https://kro.run) turns the `ResourceGraphDefinition` shipped in the component into a `HelloWorld` API and creates the OCM `Resource`, Flux `OCIRepository` and `Kustomization` objects for each instance;
- [Flux](https://fluxcd.io) fetches the Kustomize artifact and patches the placeholders in the manifests.

For the setup itself, see the OCM documentation on [controller environments](https://ocm.software/docs/getting-started/set-up-controller-environments/) and [deploying Helm charts](https://ocm.software/docs/getting-started/deploy-helm-charts/). This page covers how this repository wires them together.

## Install

`make controller` runs these commands against a kind cluster named `ocm-controller`. Each one is pinned to the version that `scripts/controller.sh` sets:

```bash
helm upgrade --install ocm-k8s-toolkit \
  oci://ghcr.io/open-component-model/kubernetes/controller/chart \
  --version 0.15.0 \
  --namespace ocm-k8s-toolkit-system --create-namespace \
  --set fullnameOverride=ocm-k8s-toolkit \
  --wait --timeout 5m
helm upgrade --install kro \
  oci://registry.k8s.io/kro/charts/kro \
  --version v0.9.4 \
  --namespace kro-system --create-namespace \
  --wait --timeout 5m
flux install --version v2.9.6
flux check
```

Flux is installed with the `flux` CLI rather than as a Helm chart. The devcontainer installs the same `v2.9.6` binary and checks its SHA-256 digest.

## Bootstrap

`k8s/controller/bootstrap.yaml` declares the repository, the component, the RGD resource, a service account with RBAC for `ResourceGraphDefinition`s, and the `NamespacedDeployer`:

```yaml
apiVersion: delivery.ocm.software/v1alpha1
kind: Repository
metadata:
  name: application-repository
  namespace: default
spec:
  repositorySpec:
    type: OCIRegistry
    baseUrl: ghcr.io/lioramilbaum/ocm
  interval: 10m
---
apiVersion: delivery.ocm.software/v1alpha1
kind: Component
metadata:
  name: application
  namespace: default
spec:
  component: github.com/lioramilbaum/application
  repositoryRef:
    name: application-repository
  semver: ">=0.1.0"
  interval: 10m
---
apiVersion: delivery.ocm.software/v1alpha1
kind: Resource
metadata:
  name: hello-world-rgd
  namespace: default
spec:
  componentRef:
    name: application
  resource:
    byReference:
      resource:
        name: hello-world-rgd
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hello-world-deployer
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hello-world-deployer
rules:
  - apiGroups: ["kro.run"]
    resources: ["resourcegraphdefinitions"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hello-world-deployer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hello-world-deployer
subjects:
  - kind: ServiceAccount
    name: hello-world-deployer
    namespace: default
---
apiVersion: delivery.ocm.software/v1alpha1
kind: NamespacedDeployer
metadata:
  name: hello-world
  namespace: default
spec:
  resourceRef:
    name: hello-world-rgd
  serviceAccountName: hello-world-deployer
```

The `NamespacedDeployer` applies `hello-world-rgd` as-is. That blob is the RGD, not the application manifests, so the deployer does not have to render `HELLO_WORLD_*` placeholders. Once the RGD is active, `k8s/controller/instance.yaml` creates one `HelloWorld` instance:

```yaml
apiVersion: kro.run/v1alpha1
kind: HelloWorld
metadata:
  name: hello-world
  namespace: default
spec:
  component: application
  architecture: amd64
  replicas: 1
  html: "Hello, World!\n"
```

`controller.sh` rewrites `architecture` to the host architecture before applying.

## How localization works

The RGD (`components/hello-world/rgd.yaml`) replaces the build-time work of `manifests.sh`, `localization.json` and `config.json` with three steps:

1. Two OCM `Resource` objects read the component. The `hello-world-image` resource gives the registry, repository and digest of the image for the instance's architecture. The `hello-world-kustomize` resource gives the location of the Flux artifact. Both publish the values in `status.additional`.
2. A Flux `OCIRepository` pins the artifact by the digest in `status.additional`. The artifact is `components/hello-world/hello-world-kustomize.oci.tar`, a Flux OCI layout that holds `manifests.yaml`. `flux-artifact.py` generates it during `make build`, and it is git-ignored rather than committed.
3. A Flux `Kustomization` applies `manifests.yaml` with three JSON patches. Each one first tests the placeholder value and then replaces it:
   - `HELLO_WORLD_IMAGE` becomes `<registry>/<repository>@<digest>`, which mirrors `localization.json`;
   - `HELLO_WORLD_REPLICAS` becomes `schema.spec.replicas`, and `HELLO_WORLD_HTML` becomes `schema.spec.html`, which mirror `config.json`.

The test suite checks that every `HELLO_WORLD_*` placeholder in `manifests.yaml` appears in the RGD, and that the instance's `replicas` equals the `config.json` value (`rgd mirrors localization and config`). The values in `instance.yaml` are not derived from `config.json`, so keep them in sync by hand.

## Usage

```bash
make controller                 # create or reuse the ocm-controller cluster, install the stack, deploy and check
KEEP_CLUSTER=1 make controller  # keep the cluster after a run that created it
OCM_CONTROLLER_REPO=ghcr.io/<you>/ocm make controller  # use another registry for the component
bash scripts/controller.sh down # delete the ocm-controller cluster
```

`make controller` requires `docker`, `kind`, `helm`, `flux` and `kubectl`. It needs internet access to pull the charts, the Flux manifests and the component from `ghcr.io`.

`controller.sh` also accepts subcommands that run one stage at a time against an existing cluster, with `KUBECONFIG` pointing at it:

- `install`: installs the OCM controllers, kro and Flux;
- `apply`: applies the bootstrap and the instance, and waits for the RGD and the `NamespacedDeployer`;
- `check`: waits for the `HelloWorld` instance and the pod, and checks that the pod answers with `Hello`;
- `down`: deletes the `ocm-controller` cluster.

The `KEEP_CLUSTER=1` setting keeps the cluster only if the run created it. A cluster that already existed is never deleted.

### Prerequisites

- `ghcr.io/lioramilbaum/ocm` must hold a published component version that contains `hello-world-rgd` and `hello-world-kustomize`. Until a tagged release publishes a version with these resources, the RGD resource is not found and `make controller` fails. Check the component with `ocm get cv ghcr.io/lioramilbaum/ocm//github.com/lioramilbaum/application`.
- The package must be public, because the controllers pull it without credentials.

### Signatures are not verified in-cluster

`make deploy` verifies the component signature before applying anything (`scripts/deploy.sh`). The controller stack does not. The OCM controller resolves and downloads the resources without checking their signatures, and Flux pulls the Kustomize artifact by digest. Trust in the cluster rests on the digest pins and on the registry. Verify the component on a workstation before relying on it. See [Signing and verification](signing.md#signing-and-verification).

## Troubleshooting

Each custom resource reports its state in `status.conditions`:

```bash
kubectl get repository.delivery.ocm.software application-repository -n default -o yaml
kubectl get component.delivery.ocm.software application -n default -o yaml
kubectl get resource.delivery.ocm.software hello-world-rgd -n default -o yaml
kubectl get namespaceddeployer.delivery.ocm.software hello-world -n default -o yaml
kubectl get resourcegraphdefinition hello-world -o yaml
kubectl get helloworld hello-world -n default -o yaml
kubectl get resource.delivery.ocm.software hello-world-kustomize -n default -o yaml
kubectl get resource.delivery.ocm.software hello-world-image -n default -o yaml
kubectl get ocirepository hello-world -n default -o yaml
kubectl get kustomization hello-world -n default -o yaml
```

The `hello-world-kustomize` and `hello-world-image` OCM resources, the `OCIRepository` and the `Kustomization` are all created by kro from the RGD, and they take the instance's name. Check `status.additional` on the two OCM `Resource` objects to see the values the patches use.

To see why a controller did not act, list its pods and read their logs:

```bash
kubectl get pods -n ocm-k8s-toolkit-system
kubectl get pods -n kro-system
kubectl logs -n kro-system <pod-name>
```
