# CAPI, CAPO, DevStack and Talos!

Try out your favourite tools and tech stack locally! :rocket:

This repository shows you step-by-step on how to run a complete environment locally to test:
* [Cluster API](https://github.com/kubernetes-sigs/cluster-api)
* [Cluster API Provider OpenStack](https://github.com/kubernetes-sigs/cluster-api-provider-openstack)
* [Minikube](https://minikube.sigs.k8s.io/docs/start/?arch=%2Flinux%2Fx86-64%2Fstable%2Fbinary+download)
* [DevStack](https://github.com/openstack/devstack)
* [Talos Linux](https://www.talos.dev/) as the workload cluster's node OS
* [OpenBao](https://openbao.org/) + [External Secrets Operator](https://external-secrets.io/) for on-demand, short-lived OpenStack credentials — no static, non-expiring password anywhere

> **Requirements up front:** the workload cluster runs [Talos Linux](https://www.talos.dev/)
> instead of kubeadm/Ubuntu. You'll need the Talos CAPI providers —
> [Cluster API Bootstrap Provider Talos (CABPT)](https://github.com/siderolabs/cluster-api-bootstrap-provider-talos)
> and [Cluster API Control Plane Provider Talos (CACPPT)](https://github.com/siderolabs/cluster-api-control-plane-provider-talos)
> — and the [`talosctl`](https://www.talos.dev/latest/talos-guides/install/talosctl/) CLI.
> Both are covered in steps 5 and 6 below.

## Overview

This drawing shows a brief overview on what we're trying to achieve:

<div align="center">
  <img src="https://github.com/user-attachments/assets/f6eed09d-52fd-4e4a-83da-0d2909bff894" alt="">
</div>

_The drawing predates the Talos/OpenBao pieces below — read it as "CAPI + CAPO
+ DevStack + minikube", not literally._

The management cluster (`minikube`) runs CAPI + CAPO + ORC. Every OpenStack
credential used to provision the workload cluster is minted on demand by
OpenBao and delivered to CAPO via External Secrets Operator — nothing static
or non-expiring is stored anywhere. The workload cluster itself is
[Talos Linux](https://www.talos.dev/) instead of kubeadm/Ubuntu: no SSH, no
`image-builder`, an immutable node image fetched on demand from Talos's
Image Factory.

**Known risk, stated up front:** Sidero Labs has stopped active development
on both CABPT and CACPPT (their READMEs point to
[Omni](https://github.com/siderolabs/omni) as the maintained alternative).
Their latest stable releases (CABPT v0.6.12, CACPPT v0.5.13) are rated for
CAPI's v1beta1 contract only — a v1beta2 track exists for CABPT
(`v0.7.0-alpha.2`) but never went GA, and CACPPT has no v1beta2 track at all,
not even alpha. This works here the same way CAPO (also v1beta1-primary)
works against a v1beta2 management cluster — via CAPI's `apiGroup`-only
`ContractVersionedObjectReference`, which resolves to whichever version a
provider's CRD actually serves — but it's an unmaintained upstream project,
not a recommended production path.

## Step-by-step

1. Deploy Devstack locally, see this [repository](https://github.com/mikejoh/devstack-on-kvm) on how to do this on top of KVM.

2. Create a `minikube` cluster:

   _This assumes that you have a KVM network called `devstack_net` available._

   ```bash
   minikube start --driver=kvm2 --kvm-network=devstack_net
   ```

3. Download `clusterctl`, change the destination directory if needed:

   ```bash
   curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.13.0/clusterctl-linux-amd64 -o ~/.local/bin/clusterctl
   ```

4. Install CAPO in the managment cluster (`minikube`):

   ```bash
   export CLUSTER_TOPOLOGY=true
   kubectl apply --server-side -f https://github.com/k-orc/openstack-resource-controller/releases/latest/download/install.yaml
   clusterctl init --infrastructure openstack
   ```

   Notes:
   * `clusterctl init` is dependant on configuration, either via environment variables or a [configuration file](https://cluster-api.sigs.k8s.io/clusterctl/configuration).
   * `cert-manager` is installed during `init`, this might not be wanted if you already have one running: https://github.com/kubernetes-sigs/cluster-api/pull/7290/files
   * ORC (OpenStack Resource Controller) is a required prerequisite for CAPO `v0.12+`; the `--server-side` apply avoids the "last-applied-configuration too long" failure on the large ORC install manifest.

5. Install the Talos providers. `clusterctl`'s built-in provider registry
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

6. Install `talosctl` — the client CLI that talks to Talos nodes directly
   over their `apid` port; there's no SSH server to fall back on:

   ```bash
   curl -Lo ~/.local/bin/talosctl https://github.com/siderolabs/talos/releases/download/v1.13.8/talosctl-linux-amd64
   chmod +x ~/.local/bin/talosctl
   talosctl version --client
   ```

   _Match the version to the Talos node image pulled in step 8 (`v1.13.8`
   here) — `talosctl` tolerates some client/node version skew, but staying
   in sync avoids surprises._

7. Set up dynamic OpenStack credentials with OpenBao — required, not
   optional, since this tutorial has no static `clouds.yaml` anywhere.
   Follow **[docs/dynamic-openstack-credentials.md](docs/dynamic-openstack-credentials.md)
   steps 1-3** (narrowly-scoped root project/user, OpenBao + the OpenStack
   secrets engine, External Secrets Operator). Its step 4 — a `capo-poc`
   sanity check — is optional; the Talos cluster in step 9 below is the
   real target and proves the same thing.

   _For the one-off `openstack` CLI commands in that doc, either SSH into
   the DevStack VM and source its admin `openrc`, or copy
   `clouds.yaml.example` to `clouds.yaml` and fill in admin credentials to
   run them from your workstation instead._

8. Get a Talos node image — no `image-builder` needed. Talos publishes
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

9. Apply `talos-devstack01/` — namespace, a one-shot roleset Job (mints the
   `talos-devstack01-member` OpenBao roleset), `VaultDynamicSecret` +
   `ExternalSecret`, `OpenStackClusterIdentity`, then the
   `Cluster`+`TalosControlPlane`+`MachineDeployment`+2×`OpenStackMachineTemplate`
   (1 control-plane + 1 worker, `TalosControlPlane`/`TalosConfigTemplate`
   in place of `KubeadmControlPlane`/`KubeadmConfigTemplate` — CAPO doesn't
   care which bootstrap provider it's wrapping). No `sshKeyName` anywhere:
   Talos has no SSH server.

   ```bash
   kubectl apply -f talos-devstack01/00-namespace.yaml
   kubectl apply -f talos-devstack01/01-roleset-job.yaml
   kubectl -n openbao wait --for=condition=complete job/roleset-talos-devstack01 --timeout=60s
   kubectl apply -f talos-devstack01/02-external-secret.yaml
   kubectl apply -f talos-devstack01/03-cluster-identity.yaml
   kubectl apply -f talos-devstack01/04-cluster.yaml
   ```

   Watch it come up — CAPO reconciles network/subnet/router/load balancer,
   then CACPPT creates the control-plane Machine once the OpenStackCluster
   is `Ready`:

   ```bash
   clusterctl describe cluster talos-devstack01 -n talos-devstack01
   NAME                                                                READY  SEVERITY  REASON  SINCE  MESSAGE
   Cluster/talos-devstack01                                            True                     8m
   ├─ClusterInfrastructure - OpenStackCluster/talos-devstack01
   └─ControlPlane - TalosControlPlane/talos-devstack01-control-plane   True                     8m
     └─Machine/talos-devstack01-control-plane-9f2k1                    True                     9m
   ```

   This is a minimal smoke test (1 control-plane + 1 worker, no
   `configPatches`) — it proves the Talos providers and image work against
   this DevStack, not a steady-state, CNI-complete cluster.

10. Connect to the cluster with `talosctl` and `kubectl`:

    ```bash
    # kubeconfig — same for any CAPI cluster, regardless of bootstrap provider
    clusterctl get kubeconfig talos-devstack01 -n talos-devstack01 > talos-devstack01.kubeconfig
    export KUBECONFIG=$PWD/talos-devstack01.kubeconfig
    kubectl get nodes

    # talosconfig — CACPPT creates it as a Secret alongside the kubeconfig one
    # (secret name may differ by CACPPT version; check with
    # `kubectl get secrets -n talos-devstack01` if this doesn't match)
    kubectl -n talos-devstack01 get secret talos-devstack01-talosconfig \
      -o jsonpath='{.data.talosconfig}' | base64 -d > talos-devstack01.talosconfig
    export TALOSCONFIG=$PWD/talos-devstack01.talosconfig

    # talosctl talks to each node's apid port directly, not the API-server
    # load balancer — grab a node's own OpenStack address
    CP_IP=$(kubectl -n talos-devstack01 get machines \
      -l cluster.x-k8s.io/control-plane \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

    talosctl -n "$CP_IP" -e "$CP_IP" version
    talosctl -n "$CP_IP" -e "$CP_IP" health
    talosctl -n "$CP_IP" -e "$CP_IP" get members
    talosctl -n "$CP_IP" -e "$CP_IP" dashboard
    ```

11. Done! 🚀

    You have a Talos-based Kubernetes cluster on DevStack, provisioned by
    CAPI/CAPO with zero static, non-expiring OpenStack credentials anywhere
    except the one root identity from
    [docs/dynamic-openstack-credentials.md](docs/dynamic-openstack-credentials.md)
    step 1.

## More

- **[Least-privilege static credentials](docs/least-privilege-openstack-credentials.md)**
  — a design doc for scoping the one remaining static "root" credential
  tightly, as an alternative to OpenBao's dynamic app-credentials.
