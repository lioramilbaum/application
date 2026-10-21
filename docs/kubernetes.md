# Kubernetes

## Kubernetes controller

The [OCM controllers](https://ocm.software/docs/concepts/kubernetes-controllers/) are a
Kubernetes operator that manages component versions declaratively. A `Repository` custom
resource points at an OCM registry and a `Component` custom resource names a component
and a semver constraint; the controller resolves and verifies the highest matching version,
records it in `status.component`, and re-checks every `interval`. This inverts `make deploy`:
instead of scripts pushing into the cluster, the cluster pulls new releases from the registry
(GitOps style). Minimal CRs for the component `release.yaml` publishes:

```yaml
apiVersion: delivery.ocm.software/v1alpha1
kind: Repository
metadata: {name: application-repository}
spec:
  repositorySpec:
    type: OCIRegistry
    baseUrl: ghcr.io/lioramilbaum/ocm
  interval: 10m
---
apiVersion: delivery.ocm.software/v1alpha1
kind: Component
metadata: {name: application}
spec:
  component: github.com/lioramilbaum/application
  repositoryRef: {name: application-repository}
  semver: ">=0.1.0"
  interval: 10m
```

The controllers and CRDs are installed by [Controller stack](controller.md), not by this page. The source is
[`bindings/go/kubernetes/controller`](https://github.com/open-component-model/open-component-model/tree/main/bindings/go/kubernetes/controller).
[Kubernetes deployer](#kubernetes-deployer) shows how to apply the manifests from the cluster.

## Kubernetes deployer

The [deployer](https://ocm.software/docs/concepts/kubernetes-deployer/) ends the controller
chain above: a `Resource` picks one resource of the `Component`, and once it is ready a
`NamespacedDeployer` server-side applies its manifests impersonating the service account named by `spec.serviceAccountName`, then
prunes and reverts drift with ApplySets. `deploy.sh` instead runs a one-shot `kubectl apply`
with the caller's credentials; here the cluster holds the desired state. The deprecated
cluster-scoped `Deployer` uses the controller's own permissions.

```yaml
apiVersion: delivery.ocm.software/v1alpha1
kind: Resource
metadata: {name: hello-world-manifests}
spec:
  componentRef: {name: application}
  resource: {byReference: {resource: {name: hello-world-manifests}}}
---
apiVersion: delivery.ocm.software/v1alpha1
kind: NamespacedDeployer
metadata: {name: hello-world}
spec: {resourceRef: {name: hello-world-manifests}, serviceAccountName: hello-world-deployer}
```

The manifests create the `hello-world` Namespace, so `hello-world-deployer` needs a `ClusterRole`.
The deployer applies the blob as-is and skips `manifests.sh` localization: `HELLO_WORLD_IMAGE`
reaches the cluster unpatched, and the controller has no `Localization` CR to fill it in
([how-to](https://ocm.software/docs/how-to/deploy-manifests-with-deployer/),
[source](https://github.com/open-component-model/open-component-model/tree/main/bindings/go/kubernetes/controller/internal/controller/deployer)).
The [controller stack](controller.md) avoids that gap differently: the deployer applies a kro `ResourceGraphDefinition`, and a Flux `Kustomization` created from it patches the `HELLO_WORLD_*` placeholders using values from OCM resource status.

## Kubernetes component discovery

The [component discovery](https://ocm.software/docs/concepts/kubernetes-component-discovery/)
controller is implemented in
[`bindings/go/kubernetes/controller`](https://github.com/open-component-model/open-component-model/tree/main/bindings/go/kubernetes/controller/internal/controller/discovery).
A `Discovery` references a same-namespace `Component` through `spec.componentRef.name`. Once that
`Component` is `Ready`, the controller resolves its entire transitive reference graph and filters
it with `resourceSelector`, `componentSelector` and `referenceSelector`. Each selector takes
`matchIdentity`, `matchLabels` or `expression` clauses. The matches are then either projected into
`status.extracted` through `extract.byResources`, or left as raw descriptors in `status.components`.

`Component` polls for new versions (semver constraints plus `interval`). `Discovery` has no interval
of its own; it re-runs when the resolved version changes. It is the in-cluster equivalent of the
`jq` resource selection in [`manifests.sh`](#kubernetes-deployer).

Discovery is read-only. It downloads nothing and gives no signature guarantee. Selecting by the
unsigned `tier` label is fine for queries but not for trust decisions; see
[Signing and verification](signing.md#signing-and-verification).

The application component has no `componentReferences`, so its graph is just the root and
`referenceSelector` has nothing to match here. A `Component` that tracks
`github.com/lioramilbaum/product` would have `application` in its reference graph, which is what
`referenceSelector` applies to; see [Component References](component-graphs.md#component-references) and
[Resolvers](repositories.md#resolvers).

```yaml
# Requires OCM controller >= v0.15.0 and the Component "application"
# from README "Kubernetes controller" in the same namespace.
apiVersion: delivery.ocm.software/v1alpha1
kind: Discovery
metadata:
  name: hello-world-images
spec:
  componentRef:
    name: application
  componentSelector:
    matchLabels:
      application.lioramilbaum.github.com/tier: application
  resourceSelector:
    matchIdentity:
      name: hello-world-image
  extract:
    byResources:
      architecture: resource.extraIdentity.architecture
      image: resource.access.imageReference
      digest: resource.digest.value
```

The expected result is two records, one per `architecture: amd64` and `architecture: arm64`. After
`make publish`, `image` is the ghcr.io copy without `@sha256`. `digest` is `resource.digest.value`;
it survives transfer unchanged, so pin by it.

A typo in a `byResources` path silently drops that field, and the controller reports no error.
`make test` guards against this by checking every path against the built descriptor.

`Discovery` requires OCM controller v0.15.0 or later.

Only consume the result when `Ready` is `True` and `status.observedGeneration` equals
`metadata.generation`:

```
kubectl get discovery hello-world-images -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
kubectl get discovery hello-world-images -o jsonpath='{.status.extracted}'
```
