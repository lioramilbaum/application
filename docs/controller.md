# Controller stack

The controller stack runs the application without `make deploy`. The cluster pulls the published component from `ghcr.io/lioramilbaum/ocm`, and three controllers do the work:

- the [OCM controllers](https://ocm.software/docs/getting-started/set-up-controller-environments/) resolve the component and the resources, and apply the `NamespacedDeployer`;
- [kro](https://kro.run) turns the `ResourceGraphDefinition` shipped in the component into a `HelloWorld` API and creates the OCM `Resource`, Flux `OCIRepository` and `Kustomization` objects for each instance;
- [Flux](https://fluxcd.io) fetches the Kustomize artifact and patches the placeholders in the manifests.

For the setup itself, see the OCM documentation on [controller environments](https://ocm.software/docs/getting-started/set-up-controller-environments/) and [deploying Helm charts](https://ocm.software/docs/getting-started/deploy-helm-charts/). This page covers how this repository wires them together. To run the same stack without internet access, see [Air-gapped target](bootstrap.md).

## Install

`make controller` runs these commands against a kind cluster named `ocm-controller`. The chart versions and the Flux version are the `OCM_CONTROLLER_CHART_VERSION`, `KRO_CHART_VERSION` and `FLUX_VERSION` constants in `scripts/controller.sh`; Renovate updates them there:

```bash
helm upgrade --install ocm-k8s-toolkit \
  oci://ghcr.io/open-component-model/kubernetes/controller/chart \
  --version "$OCM_CONTROLLER_CHART_VERSION" \
  --namespace ocm-k8s-toolkit-system --create-namespace \
  --set fullnameOverride=ocm-k8s-toolkit \
  --wait --timeout 5m
helm upgrade --install kro \
  oci://registry.k8s.io/kro/charts/kro \
  --version "$KRO_CHART_VERSION" \
  --namespace kro-system --create-namespace \
  --wait --timeout 5m
flux install --version "$FLUX_VERSION"
flux check
kubectl apply -f k8s/controller/rbac.yaml
```

Flux is installed with the `flux` CLI rather than as a Helm chart. The devcontainer installs the `flux` binary at the version pinned by `FLUX_VERSION` in `.devcontainer/Dockerfile` and checks its SHA-256 digest.

`FLUX_MANIFESTS` replaces `flux install` and `flux check`: `controller.sh` applies that file with `kubectl` and waits for the Flux deployments to become available. The [air-gapped path](bootstrap.md) uses this with the manifest in its bundle.

`k8s/controller/rbac.yaml` is part of the environment, not of the application, so `install` applies it with the stack. It lets the OCM controller read the RGDs it deploys:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ocm-controller-hello-world
rules:
  - apiGroups: ["kro.run"]
    resources: ["resourcegraphdefinitions"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ocm-controller-hello-world
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ocm-controller-hello-world
subjects:
  - kind: ServiceAccount
    name: ocm-k8s-toolkit-controller-manager
    namespace: ocm-k8s-toolkit-system
```

The OCM controller reads the RGD before it applies it, so it needs `get`, `list` and `watch` on `resourcegraphdefinitions`. The service account name follows `fullnameOverride=ocm-k8s-toolkit` in the chart install.

## Deploy manifest

`k8s/controller/deploy.yaml` deploys the application. It declares the repository, the component, the RGD resource, a service account with RBAC for `ResourceGraphDefinition`s, and the `NamespacedDeployer`:

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

`controller.sh` renders the instance with the host architecture before it applies it. The deploy manifest and the instance are also resources of the component (`hello-world-deploy` and `hello-world-instance`), so the air-gapped path (`targetctl.sh deploy`) takes them from the signed component.

## How localization works

The RGD (`components/hello-world/rgd.yaml`) replaces the build-time work of `manifests.sh`, `localization.json` and `config.json` with three steps:

1. Two OCM `Resource` objects read the component. Each one publishes `resource.access.toOCI()` in `status.additional.oci`. The `hello-world-image` resource is selected by the instance's `architecture`, and the `hello-world-kustomize` resource is the Flux artifact. `toOCI()` gives the registry, the repository and the digest, and it accepts the `http://` form that `ocm transfer` leaves behind. Both resources report `Ready` before the next step runs.
2. A Flux `OCIRepository` pins the artifact by the digest in `status.additional.oci`. Its `insecure` field comes from the instance, which is how the air-gapped path reads a plain-HTTP registry. The artifact is `components/hello-world/hello-world-kustomize.oci.tar`, a Flux OCI layout that holds `manifests.yaml`. `flux-artifact.py` generates it during `make build`, and it is git-ignored rather than committed.
3. A Flux `Kustomization` applies `manifests.yaml` with three JSON patches. Each one first tests the placeholder value and then replaces it:
   - `HELLO_WORLD_IMAGE` becomes `<registry>/<repository>@<digest>` from the image resource, which mirrors `localization.json`;
   - `HELLO_WORLD_REPLICAS` becomes `schema.spec.replicas`, and `HELLO_WORLD_HTML` becomes `schema.spec.html`, which mirror `config.json`.

The RGD uses the kro SimpleSchema form for its spec (`component: string | default="application"` and so on). It passes `byReference.resource` to OCM as a flat identity: `name` plus, for the image, `architecture`.

The test suite checks that every `HELLO_WORLD_*` placeholder in `manifests.yaml` appears in the RGD, and that the instance's `replicas` equals the `config.json` value (`rgd mirrors localization and config`). The values in `instance.yaml` are not derived from `config.json`, so keep them in sync by hand.

## Usage

```bash
make controller                 # create or reuse the ocm-controller cluster, install the stack, deploy and check
KEEP_CLUSTER=1 make controller  # keep the cluster after a run that created it
OCM_CONTROLLER_REPO=ghcr.io/<you>/ocm make controller  # use another registry for the component
bash scripts/controller.sh down # delete the ocm-controller cluster
```

`make controller` requires `docker`, `kind`, `helm`, `flux` and `kubectl`. It needs internet access to pull the charts, the Flux manifests and the component from `ghcr.io`. `controller.sh install` applies `k8s/controller/rbac.yaml` with the stack, so `make controller` grants the controller RBAC at install time, before the deploy manifest is applied; the deploy manifest itself no longer carries it.

`controller.sh` also accepts subcommands that run one stage at a time against an existing cluster, with `KUBECONFIG` pointing at it:

- `install`: installs the OCM controllers, kro and Flux, and applies the controller RBAC (`k8s/controller/rbac.yaml`);
- `apply`: applies the deploy manifest and the instance, and waits for the RGD and the `NamespacedDeployer`;
- `check`: waits for the `HelloWorld` instance and the pod, and checks that the pod answers with `Hello`;
- `down`: deletes the `ocm-controller` cluster.

The `KEEP_CLUSTER=1` setting keeps the cluster only if the run created it. A cluster that already existed is never deleted.

### Overrides

These environment variables change where `controller.sh` reads its inputs. Each default is the online value:

| Variable | Default | Effect |
|---|---|---|
| `OCM_CONTROLLER_REPO` | `ghcr.io/lioramilbaum/ocm` | The `baseUrl` of the `Repository`, replaced in the deploy manifest |
| `OCM_CONTROLLER_CHART` | `oci://ghcr.io/open-component-model/kubernetes/controller/chart` | The OCM controller chart. A local `.tgz` path installs without `--version` |
| `KRO_CHART` | `oci://registry.k8s.io/kro/charts/kro` | The kro chart. A local `.tgz` path installs without `--version` |
| `FLUX_MANIFESTS` | unset | A Flux install manifest applied with `kubectl`, in place of `flux install` |
| `DEPLOY_FILE` | `k8s/controller/deploy.yaml` | The deploy manifest that `apply` renders |
| `INSTANCE_FILE` | `k8s/controller/instance.yaml` | The instance manifest that `apply` renders |
| `OCM_CONTROLLER_INSECURE` | `false` | `true` sets `insecure: true` on the `HelloWorld` instance, for a plain-HTTP registry |

`apply` renders each manifest with `kubectl kustomize` and a JSON 6902 patch. The patch first tests the value the file ships with (the `baseUrl` `ghcr.io/lioramilbaum/ocm` and the `architecture` `amd64`), then replaces it. If the file no longer carries the shipped value, the render fails. kustomize does not fail when a patch target matches nothing; it renders the file unchanged. So `apply` also checks the rendered output: the `Repository` `application-repository` must have `baseUrl` set to `OCM_CONTROLLER_REPO`, and the `HelloWorld` `hello-world` must have `architecture` set to the host architecture (and `insecure: true` when `OCM_CONTROLLER_INSECURE=true`). Each check needs exactly one object of that kind and name. Both manifests are rendered and checked before anything is applied, and a failed check names the file and stops the run. This replaces a text substitution, which would have changed nothing silently.

### Prerequisites

- `ghcr.io/lioramilbaum/ocm` must hold a published component version that contains `hello-world-rgd`, `hello-world-kustomize`, `hello-world-deploy` and `hello-world-instance`. Until a tagged release publishes a version with these resources, the RGD resource is not found and `make controller` fails. Check the component with `ocm get cv ghcr.io/lioramilbaum/ocm//github.com/lioramilbaum/application`.
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

The `hello-world-kustomize` and `hello-world-image` OCM resources, the `OCIRepository` and the `Kustomization` are all created by kro from the RGD, and they take the instance's name. Check `status.additional.oci` on the two OCM `Resource` objects to see the values the patches use.

To see why a controller did not act, list its pods and read their logs:

```bash
kubectl get pods -n ocm-k8s-toolkit-system
kubectl get pods -n kro-system
kubectl logs -n kro-system <pod-name>
```
