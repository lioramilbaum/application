# Air-gapped target: bootstrap, transfer and deploy

The [controller stack](controller.md) normally pulls its Helm charts, the Flux manifests, the platform images, the component and the application image from the internet. The air-gapped path runs the same stack on a target with no internet access.

Everything online happens on the source side, in one step that writes a bundle. Everything on the target side runs offline from that bundle. The target side has three stages:

- **bootstrap** makes the environment ready: the cluster, the platform images, a registry and the controller stack.
- **transfer** puts the application component into that registry.
- **deploy** deploys the application, and only the application.

The work is split between two scripts by side. `scripts/sourcectl.sh` runs where the internet is, and `scripts/targetctl.sh` runs where the cluster is. `scripts/bootstrap-bundle.sh` holds what both share: the bundle layout, the image archive names, the registry image pin and the verify config.

| Command | Side | Runs | Makefile target | What it does |
|---|---|---|---|---|
| `sourcectl.sh bundle` | source | online | `make package` | Writes the bundle, always |
| `sourcectl.sh check` | source | no network, reads `build/` | part of `make source` | Tells whether the bundle is missing or stale |
| `targetctl.sh cluster` | target | before the gap in CI | `make target-cluster` | Creates the stand-in kind cluster, or reuses it |
| `targetctl.sh bootstrap` | target | offline | `make target-bootstrap` | Prepares the environment; creates the cluster first when it is missing |
| `targetctl.sh transfer` | target | offline | `make target-transfer` | Puts the component into the target registry |
| `targetctl.sh deploy` | target | offline | `make target-deploy` | Deploys the application and checks it |
| `targetctl.sh up` | target | offline | `make target` | bootstrap, transfer and deploy; leaves everything running |
| `targetctl.sh down` | target | | `make target-down` | Deletes the `ocm-bootstrap` cluster and the registry |

The Makefile groups these by side:

- `make source` covers every online step. After `make build sign`, it runs `sourcectl.sh check` and runs `sourcectl.sh bundle` only when the bundle is missing or stale.
- `make target` covers every offline step.
- `make up` runs `make source` and then `make target`.
- `make bootstrap` runs `make source` and then only `targetctl.sh bootstrap`, which leaves a ready environment for `make target-transfer` and `make target-deploy`.

The two sides never do each other's work. `sourcectl.sh` never touches the cluster or Docker. `targetctl.sh` never pulls anything, never reads `build/ctf` and never writes the bundle.

In CI, the `package` job of `e2e.yaml` runs `sourcectl.sh bundle` on the CLI artifact. The `e2e (controller)` leg runs `make target-cluster` before the egress block, to create the stand-in kind cluster. Inside the block it runs bootstrap, transfer and deploy as three separate steps. If the `package` job fails, `e2e (controller)` fails before downloading the bundle, and the `e2e (cli)` leg still runs. The `e2e (cli)` leg runs the CLI path on the same kind network, with the same block and the same packet capture. Its steps are unchanged, but its cluster now comes from the same pinned node image (see [Enforcement model](#enforcement-model)).

## The bundle

`sourcectl.sh bundle` writes `build/bootstrap-bundle/`. This directory is the only thing that crosses the gap:

| Path | Contents | Why it is there |
|---|---|---|
| `ctf/` | The application component, transferred with [publish.sh](transfer.md) | Every external resource (the nginx image) is inlined as a local blob, so the component is self-contained. The signature survives the transfer. |
| `charts/ocm-k8s-toolkit.tgz`, `charts/kro.tgz` | The Helm charts, pulled at the versions `scripts/controller.sh` pins | Installed from files, so no `oci://` reference is needed on the target |
| `flux/install.yaml` | `flux install --export` for `source-controller` and `kustomize-controller` at `FLUX_VERSION` | Applied with `kubectl`, not with the `flux` CLI |
| `images.txt` | Every container image the charts and Flux manifests name, with quotes removed, one per line | The node images: each has an archive in `images/` |
| `images/<image>.tar` | One OCI image layout per line of `images.txt`, for linux/amd64 and linux/arm64 | Loaded into every node's containerd by `targetctl.sh bootstrap` |
| `images/registry.tar` | The `registry:2` image for linux/amd64 and linux/arm64 | Loaded into the host's Docker by `targetctl.sh bootstrap` |
| `public.pem` | The public key that verifies the signature | The target verifies the component without any key distribution step |
| `source.stamp` | Digests of the CTF index (`build/ctf/artifact-index.json`), of the public key and of the platform pins that the bundle was built from | `sourcectl.sh check` compares it with the current build, so `make source` rebuilds the bundle when the component, the key, a chart or Flux version, or the registry pin changes. `targetctl.sh` does not read it |

The deploy manifests are not in the bundle. They are resources of the component (`hello-world-deploy` and `hello-world-instance`), so they reach the target through the same signed component as the application.

`sourcectl.sh bundle` verifies the transferred CTF with `public.pem` before it pulls the charts, so a bundle that fails verification is never completed.

`sourcectl.sh bundle` deletes and rebuilds `$BOOTSTRAP_BUNDLE_DIR`. It therefore refuses any `BOOTSTRAP_BUNDLE_DIR` that:

- is not a subdirectory of `BUILD_DIR`;
- has a `.` or `..` part;
- passes through a symlink below `BUILD_DIR`.

Nothing is deleted in that case.

## Platform images

The platform images are saved with OCM, which the devcontainer already has. `sourcectl.sh bundle` puts every line of `images.txt`, plus `BOOTSTRAP_REGISTRY_IMAGE`, into a scratch component as `ociImage` resources, then:

1. resolves each reference to the digest of its upstream index with `ocm add cv`. A reference pinned by digest must resolve to that digest, or the bundle fails with `not its pinned digest`.
2. downloads each image by that digest as an OCI layout with `ocm download resource`, and checks that the layout holds the digest.
3. prunes the layout to linux/amd64 and linux/arm64. The index blob stays byte for byte, so its digest still matches. The manifests of other platforms, attestation and signature manifests, and the blobs only they use are removed: nothing on the target runs or reads them.
4. names the image the way it is looked up, and archives the layout:
   - A **node image** is named in the layout's `index.json` (`io.containerd.image.name`) by `<repository>@<digest>`, and by `<repository>:<tag>` when the reference has a tag. The repository is in containerd's full form, so `registry:2` becomes `docker.io/library/registry`.
   - The **registry image** runs on the host, where Docker loads it. Its archive keeps the pinned index blob and tags each platform's manifest as `ocm-bootstrap/registry:sha256-<pin>-amd64` and `-arm64`. The tags are written both in `index.json`, for Docker's containerd image store, and in a Docker `manifest.json`, for the classic image store. A local name never clashes with a `registry:2` the host already has.

The archives make up most of the bundle. With the versions pinned today, the bundle is about 560 MB, of which the image archives are about 510 MB: the OCM controller about 190 MB, each Flux controller about 140 MB, kro about 30 MB and the registry about 20 MB. The figures change with the pinned versions; `make package` prints the size in CI.

## Bootstrap

`targetctl.sh bootstrap` never names an internet host, and it runs its host-side commands behind an unreachable proxy (see [Enforcement model](#enforcement-model)). It runs these steps in order, and each one stops the run with a message that names what is missing:

1. Check that the bundle holds every file in the list above, including an archive for every line of `images.txt`.
2. Check the archives before anything is created:
   - each node image archive names its image by digest and tag;
   - the registry archive holds the pinned index blob, whose hash matches the pin;
   - that index lists a manifest for the host's platform, and the archive tags that manifest for the host.
3. Create the `ocm-bootstrap` kind cluster from the pinned node image (`scripts/cluster.sh`), unless `targetctl.sh cluster` already created it; an existing cluster is reused. This is the same code as `targetctl.sh cluster`. The kind config sets `config_path = "/etc/containerd/certs.d"` in `containerdConfigPatches`, so containerd reads the registry host files of step 8. kind copies proxy variables into the nodes, so it runs without them.
4. `docker load` the registry archive. The loaded image's ID must be the checked manifest (containerd image store) or its config (classic image store).
5. Import every node image into every node with `ctr --namespace=k8s.io images import --platform linux/<node architecture>`.
6. Check that every line of `images.txt` resolves on every node with `crictl inspecti`, the lookup kubelet does. An image that does not resolve is imported once more; if it still does not resolve, the run fails.
7. Start the registry on the `kind` Docker network with `--network kind --pull never` and the host platform's tag. It publishes no port to the host. Read its IP address.
8. Write a containerd `hosts.toml` for `<ip>:5000` on every node (`scripts/cluster.sh`, via `KIND_REGISTRY_HOST`), so the nodes pull from the registry over plain HTTP.
9. Install the controller stack with `scripts/controller.sh install`, pointing `OCM_CONTROLLER_CHART`, `KRO_CHART` and `FLUX_MANIFESTS` at the bundle files. `install` also applies `k8s/controller/rbac.yaml`, which lets the OCM controller read the RGDs it deploys.

Nothing of the application is transferred or applied. Running `bootstrap` again recreates the registry empty, so run `transfer` again after it.

## Transfer

`targetctl.sh transfer` moves the application component from the bundle into the registry that `bootstrap` started:

1. Check that the bundle is complete.
2. Verify the bundle CTF against `public.pem`.
3. Check that the bundle is self-contained: every resource must be a local blob. A resource that refers to an outside location fails the run and is named in the message.
4. Find the registry on the `kind` network. Without it, `transfer` fails and says to run `make target-bootstrap`.
5. Transfer the bundle CTF to `oci::http://<ip>:5000/ocm` with `publish.sh` and `transfer.ocmconfig`. The uploaders store each local OCI image as an OCI artifact the kubelet can pull. `transfer.ocmconfig` gives each `hello-world-image` architecture its own tag (`1.31-alpine-amd64`, `1.31-alpine-arm64`). Without it, both variants would share one tag, and the last upload would win.
6. Verify the registry copy.

## Deploy

`targetctl.sh deploy` deploys the application from the registry copy:

1. Find the registry, and check that it holds the component. Without the registry, `deploy` fails and says to run `make target-bootstrap`. Without the component, it says to run `make target-transfer`.
2. Verify the registry copy against `public.pem` again. `transfer` and `deploy` are separate commands, so the registry may have changed in between.
3. Download `hello-world-deploy` and `hello-world-instance` from the registry copy, and compare each file's SHA-256 with its descriptor digest.
4. Apply them with `scripts/controller.sh apply`, with `OCM_CONTROLLER_REPO=http://<ip>:5000/ocm` and `OCM_CONTROLLER_INSECURE=true`.
5. Run `scripts/controller.sh check`, then check that every running `hello-world` pod uses an image that starts with `<ip>:5000/`.

The application image is never staged on the nodes. It has to come through the component, so `deploy` can only run it from the registry copy.

## Registry and the two-hop transfer

The registry is a container on the `kind` network, so the nodes reach it at its bridge address. The devcontainer uses the host network and can route to that address too, but it cannot resolve container names, so the target side uses the IP address. `scripts/registry.sh` does not serve this path: it publishes on `127.0.0.1` on the default bridge, which the nodes cannot reach.

Plain HTTP is used on purpose. The registry has no TLS certificate, and `hosts.toml` declares the endpoint as `http://<ip>:5000`. The `Repository` and the `HelloWorld` instance carry `http://<ip>:5000/ocm`. `OCM_CONTROLLER_INSECURE=true` sets `insecure: true` on the instance, so the Flux `OCIRepository` also reads the registry over HTTP.

The component is moved in two hops. The first is the bundle, an archive on disk that crosses the gap. The second is `transfer`, which runs `publish.sh` from the bundle to the registry. The controller then reads the component from the registry copy, so no step needs the original CTF.

## Component-sourced deploy

The OCM controller reads its `Repository` and `Component` from `k8s/controller/deploy.yaml`, and the Kustomize render of `hello-world-kustomize` happens in Flux. Two things differ on the air-gapped path:

- **The manifests come from the component.** `targetctl.sh deploy` downloads them from the registry copy and checks them against their descriptor digests, so a tampered file stops the run before anything is applied.
- **The local values are set with JSON 6902 patches in `scripts/controller.sh`.** Each patch first tests the value the file ships with (`ghcr.io/lioramilbaum/ocm` for `baseUrl`, `amd64` for `architecture`) and then replaces it, so a manifest that no longer matches the default fails the render with `kubectl kustomize`. A patch whose target matches nothing does not fail kustomize, so `apply` also checks the rendered output:
  - the `Repository` `application-repository` must carry the registry URL;
  - the `HelloWorld` `hello-world` must carry the host architecture.

  Both files are rendered and checked before anything is applied.

The `ResourceGraphDefinition` in the component uses `resource.access.toOCI()`, which resolves a local blob to a `<registry>/<repository>@<digest>` reference for both the image and the Kustomize artifact. This is what makes the RGD work with a registry that is not `ghcr.io`.

As on the online path, the controllers do not verify signatures. `targetctl.sh transfer` and `deploy` verify the component with the `ocm` CLI before they use it. See [Signing is not verified in-cluster](controller.md#signatures-are-not-verified-in-cluster).

## Enforcement model

The target side runs no online command. Only `make source` (`sourcectl.sh bundle`) goes online, and it runs before the gap.

The one input that does not come from the bundle is the kind node image (`kindest/node`, pinned by digest in `scripts/cluster.sh`). kind stands in for the site's own Kubernetes cluster, which a real site already has, so the node image is not bundled. It is staged before the gap: the host's Docker pulls it the first time a cluster is created. Every kind cluster in the repository uses this pin, not only the target: the `e2e (cli)` leg, `make e2e`, `make controller` and `targetctl.sh bootstrap`. It is the image kind v0.33.0 uses by default. Renovate updates the pin; it must stay a node image that the release notes of the pinned kind version list.

The CI check that blocks the air-gapped egress is an iptables rule on the `DOCKER-USER` chain. It drops new connections that leave the kind bridge, and a `tcpdump` capture on that bridge records what got through. In the `e2e (controller)` leg the stand-in cluster is created before the block (`make target-cluster`): the kind node entrypoint resolves `host.docker.internal`, and Docker's embedded DNS forwards that query upstream from the node, which the capture would record as a packet to a public resolver. Everything else on the target side runs inside the block, so the capture covers image loading, the registry, the controller install, the transfer and the deploy. The leg must report no packets to public addresses on that bridge.

The block and the capture cover only the kind bridge. The devcontainer runs on the host network, and the host-side commands (`ocm`, `helm`, `kubectl`, `docker`) run in it, so CI does not isolate them from the internet and the capture does not see their traffic. Host-side tools are therefore offline by construction, by the tests and by the guards below, not by CI.

`targetctl.sh` enforces this itself:

- `transfer` rejects any CTF with a resource that is not a local blob before it moves anything, so the component has no reference that would need the internet.
- No subcommand runs `helm pull`, `flux install`, `docker pull`, `crictl pull`, `kind load` or any `oci://` reference. The only network targets they name are the registry on the kind network and the local cluster.
- `bootstrap`, `transfer` and `deploy` run their host-side commands behind an unreachable proxy:
  - `HTTP_PROXY`, `HTTPS_PROXY` and their lowercase forms are set to `http://127.0.0.1:9`, a port with no listener, so an accidental request to an internet host fails at once.
  - `NO_PROXY` lists `localhost`, `127.0.0.1`, the API server host from the kubeconfig (an IPv6 address without its brackets) and the registry IP, so the cluster and the registry stay reachable.
  - Go clients (`ocm`, `helm`, `kubectl`) never proxy loopback addresses on their own, and `curl` honours `NO_PROXY` for IP addresses.
  - kind creates the cluster without these variables, because it would copy them into the nodes.
  - The proxy catches accidental calls; a process can still unset the variables.

## Usage

```bash
make build sign             # build and sign the component (keys in build/keys)
make source                 # online: write the bundle when missing or stale (make package always rewrites it)
make target-cluster        # create the stand-in kind cluster (CI does this before the egress block; bootstrap does it when missing)
make bootstrap              # make source, then prepare the environment offline (cluster, images, registry, controllers)
make target-transfer        # offline: put the component into the target registry
make target-deploy          # offline: deploy the application and check it
make up                     # make source, then make target (bootstrap, transfer and deploy); leaves everything running
make target-down            # delete the ocm-bootstrap cluster and the registry
```

Run these in the devcontainer. The target side talks to the registry at its address on the `kind` network, and on Docker Desktop only the devcontainer's host network can reach that address. `make target` and `make up` leave the cluster and the registry running, and `make target-down` removes them.

| Variable | Default | Meaning |
|---|---|---|
| `BOOTSTRAP_BUNDLE_DIR` | `build/bootstrap-bundle` | Where the bundle is written and read. A subdirectory of `BUILD_DIR`, because `sourcectl.sh bundle` deletes and rebuilds it |
| `KIND_CLUSTER` | `ocm-bootstrap` | Name of the kind cluster |
| `KIND_NODE_IMAGE` | the `kindest/node` pin in `scripts/cluster.sh` | Node image of every kind cluster |
| `BOOTSTRAP_REGISTRY_NAME` | `ocm-bootstrap-registry` | Name of the registry container |
| `BOOTSTRAP_REGISTRY_IMAGE` | the `registry:2` digest that `scripts/registry.sh` uses (pinned in `scripts/bootstrap-bundle.sh`) | Registry image. `sourcectl.sh bundle` saves it into `images/registry.tar` |

Versions come from `scripts/controller.sh`: `OCM_CONTROLLER_CHART_VERSION`, `KRO_CHART_VERSION` and `FLUX_VERSION`.

## Troubleshooting

- `bootstrap bundle is incomplete`: a file in the list above is missing. Rebuild the bundle with `make package`, or copy the whole directory.
- `platform image ... resolved to ..., not its pinned digest` (`make package`): the upstream image behind a pinned reference changed. Check the chart version or the registry pin.
- `... does not hold ...` or `... does not tag ...` (`bootstrap`): an archive does not carry the name a node or Docker looks up, or the registry archive does not match the pin. Rebuild the bundle with `make package`.
- `image ... is not on node ... after importing ...`: the image did not resolve on that node even after a second import. Rebuild the bundle with `make package`. A node whose disk is more than 85% full can also lose loaded images: kubelet's image garbage collection removes images that no pod uses yet. Free disk space on the target and run `make target-bootstrap` again.
- `registry ... is not running on the kind network`: `transfer` and `deploy` need the registry that `bootstrap` starts. Run `make target-bootstrap`.
- `component ... is not in the registry`: run `make target-transfer` before `make target-deploy`. A new `bootstrap` empties the registry.
- `bundle signature does not verify` or `registry copy does not verify`: `public.pem` does not match the key the CTF was signed with. Copy both from the same `build` directory.
- `bundle is not self-contained`: the named resources are external. Rebuild the bundle; `sourcectl.sh bundle` inlines external resources through `publish.sh`.
- `make source` rebuilds the bundle every time: `source.stamp` does not match the current build, for example because `make build sign` runs before each `make source`. Rebuilding is then expected.
- `... does not match its descriptor digest`: the file changed between the bundle and the target, or the registry copy was altered. Rebuild, then transfer again.
- `pod runs ... not an image from the bootstrap registry`: the Flux `Kustomization` did not resolve the image from the registry. Check the `Resource` objects with `kubectl get resource.delivery.ocm.software hello-world-image -n default -o yaml` and the `status.additional.oci` field.
- `registry not reachable`: the registry container did not start on the `kind` network. Check `docker logs ocm-bootstrap-registry`.
- `BOOTSTRAP_BUNDLE_DIR must be a directory under BUILD_DIR`: `sourcectl.sh bundle` refuses to delete a directory outside `BUILD_DIR`. Point `BOOTSTRAP_BUNDLE_DIR` at a subdirectory of it.
- `BOOTSTRAP_BUNDLE_DIR must not pass through a symlink under BUILD_DIR`: a symlink there could point the deletion outside `BUILD_DIR`. Point `BOOTSTRAP_BUNDLE_DIR` at a real subdirectory.
- `does not render Repository ...` or `does not render HelloWorld ...`: the file no longer has the object that `scripts/controller.sh` patches, or its shipped value changed, so `apply` stops before anything is applied. Check the names in the file against the patches in `scripts/controller.sh`.

The CI artifact `application-bootstrap-bundle` holds the bundle that the `e2e (controller)` leg downloads. Its retention is one day.
