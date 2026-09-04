# Bonus: Talos instead of kubeadm

An alternative bootstrap path — [Talos Linux](https://www.talos.dev/) instead
of kubeadm, via [Cluster API Bootstrap Provider Talos
(CABPT)](https://github.com/siderolabs/cluster-api-bootstrap-provider-talos)
and [Cluster API Control Plane Provider Talos
(CACPPT)](https://github.com/siderolabs/cluster-api-control-plane-provider-talos).
Kept separate from the [main walkthrough](../README.md) (`talos-devstack01/`,
own namespace, own OpenBao roleset) — it doesn't replace the main walkthrough
or the [dynamic-credential bonus](dynamic-openstack-credentials.md), it's a
sibling that reuses the same OpenBao/ESO dynamic-credential chain.

**Known risk, stated up front:** Sidero Labs has stopped active development
on both CABPT and CACPPT (their READMEs point to
[Omni](https://github.com/siderolabs/omni) as the maintained alternative).
Their latest stable releases (CABPT v0.6.12, CACPPT v0.5.13) are rated for
CAPI's v1beta1 contract only — a v1beta2 track exists for CABPT
(`v0.7.0-alpha.2`) but never went GA, and CACPPT has no v1beta2 track at all,
not even alpha. This works here the same way CAPO (also v1beta1-primary)
already works against this repo's CAPI v1.13.0/v1beta2 management cluster —
via CAPI's `apiGroup`-only `ContractVersionedObjectReference`, which resolves
to whichever version a provider's CRD actually serves — but it's an
unmaintained upstream project, not a recommended production path.

1. Install the Talos providers. `clusterctl`'s built-in provider registry
   still points at the old `talos-systems` GitHub org (renamed to
   `siderolabs`), which breaks bare `clusterctl init -b talos -c talos`
   with a misleading `target namespace can't be defaulted` error. Work
   around it with explicit provider URLs — note the shape:
   `.../releases/<version>/<file>`, *not* GitHub's literal
   `.../releases/download/<tag>/<file>` asset path (`clusterctl` inserts
   `download` itself when resolving):

   ```yaml
   # ~/.cluster-api/clusterctl.yaml
   providers:
     - name: "talos"
       url: "https://github.com/siderolabs/cluster-api-bootstrap-provider-talos/releases/v0.6.12/bootstrap-components.yaml"
       type: "BootstrapProvider"
     - name: "talos"
       url: "https://github.com/siderolabs/cluster-api-control-plane-provider-talos/releases/v0.5.13/control-plane-components.yaml"
       type: "ControlPlaneProvider"
   ```

   ```bash
   clusterctl init --bootstrap talos --control-plane talos
   ```

2. Get a Talos node image — no `image-builder` needed. Talos publishes
   per-platform disk images on demand via [Image
   Factory](https://factory.talos.dev) instead of baking a fixed set of
   releases:

   ```bash
   SCHEMATIC=$(curl -s -X POST https://factory.talos.dev/schematics \
     -H "Content-Type: application/yaml" --data "customization: {}" \
     | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

   curl -sL -o talos-openstack.raw.xz \
     "https://factory.talos.dev/image/${SCHEMATIC}/v1.13.8/openstack-amd64.raw.xz"
   xz -d talos-openstack.raw.xz

   openstack image create "talos-1.13.8-openstack" \
     --progress \
     --disk-format raw \
     --property os_type=linux \
     --property os_distro=talos \
     --file talos-openstack.raw
   ```

3. Apply `talos-devstack01/` — same shape as `k8s-devstack01/` (namespace,
   a one-shot roleset Job, `VaultDynamicSecret`+`ExternalSecret`,
   `OpenStackClusterIdentity`), but `04-cluster.yaml` swaps
   `KubeadmControlPlane`/`KubeadmConfigTemplate` for
   `TalosControlPlane`/`TalosConfigTemplate` (`generateType:
   controlplane`/`worker` — CACPPT/CABPT's own bare-minimum form, no
   hand-written Talos machine config needed). No `sshKeyName` anywhere:
   Talos has no SSH server.

   ```bash
   kubectl apply -f talos-devstack01/00-namespace.yaml
   kubectl apply -f talos-devstack01/01-roleset-job.yaml
   kubectl -n openbao wait --for=condition=complete job/roleset-talos-devstack01 --timeout=60s
   kubectl apply -f talos-devstack01/02-external-secret.yaml
   kubectl apply -f talos-devstack01/03-cluster-identity.yaml
   kubectl apply -f talos-devstack01/04-cluster.yaml
   ```

4. Watch it come up — CAPO reconciles network/subnet/router/load balancer
   exactly like `capo-poc`, then CACPPT creates the control-plane Machine
   once the OpenStackCluster is `Ready`:

   ```bash
   kubectl -n talos-devstack01 get cluster,openstackcluster,taloscontrolplane,machines
   ```

   This is a minimal smoke test (1 control-plane + 1 worker, no
   `configPatches`) — it proves the Talos providers and image work against
   this DevStack, not a steady-state cluster. No OCCM/CNI/ArgoCD migration
   wired up for it; that's the kubeadm path's job (steps 13-18 of the
   [main walkthrough](../README.md)).
