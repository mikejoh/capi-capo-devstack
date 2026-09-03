# CAPI, CAPO and DevStack!

Try out your favourite tools and tech stack locally! :rocket:

This repository shows you step-by-step on how to run a complete environment locally to test:
* [Cluster API](https://github.com/kubernetes-sigs/cluster-api)
* [Cluster API Provider OpenStack](https://github.com/kubernetes-sigs/cluster-api-provider-openstack)
* [Minikube](https://minikube.sigs.k8s.io/docs/start/?arch=%2Flinux%2Fx86-64%2Fstable%2Fbinary+download)
* [DevStack](https://github.com/openstack/devstack)
* [Cilium](https://cilium.io/) as CNI, installed and managed by [ArgoCD](https://argo-cd.readthedocs.io/)

## Overview

This drawing shows a brief overview on what we're trying to achieve:

<div align="center">
  <img src="https://github.com/user-attachments/assets/f6eed09d-52fd-4e4a-83da-0d2909bff894" alt="">
</div>

The workload cluster is brought up with kube-proxy disabled at the kubeadm layer. A minimal Flannel install bootstraps the pod network so ArgoCD can run; ArgoCD then installs Cilium (with `kubeProxyReplacement: true`) and, via a second Application, runs a one-shot Job that deletes Flannel and rolling-restarts pods so they re-IP via Cilium.

## Step-by-step

1. Deploy Devstack locally, see this [repository](https://github.com/mikejoh/devstack-on-kvm) on how to do this on top of KVM.

2. Download the OpenStack RC file via Horizon.

3. Create a `minikube` cluster:

_This assumes that you have a KVM network called `devstack_net` available._

```bash
minikube start --driver=kvm2 --kvm-network=devstack_net
```

4. Download `clusterctl`, change the destination directory if needed:

```bash
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.13.0/clusterctl-linux-amd64 -o ~/.local/bin/clusterctl
```

5. Install CAPO in the managment cluster (`minikube`):

```bash
export CLUSTER_TOPOLOGY=true
kubectl apply --server-side -f https://github.com/k-orc/openstack-resource-controller/releases/latest/download/install.yaml
clusterctl init --infrastructure openstack
```

Notes:
* `clusterctl init` is dependant on configuration, either via environment variables or a [configuration file](https://cluster-api.sigs.k8s.io/clusterctl/configuration).
* `cert-manager` is installed during `init`, this might not be wanted if you already have one running: https://github.com/kubernetes-sigs/cluster-api/pull/7290/files
* The default bootstrap providers are `kubeadm`, you can select others.
* ORC (OpenStack Resource Controller) is a required prerequisite for CAPO `v0.12+`; the `--server-side` apply avoids the "last-applied-configuration too long" failure on the large ORC install manifest.

6. Build an image using [`image-builder`](https://image-builder.sigs.k8s.io/capi/providers/openstack.html), used the `qemu` builder:

```bash
git clone https://github.com/kubernetes-sigs/image-builder.git
cd image-builder/images/capi/
make build-qemu-ubuntu-2404 KUBERNETES_VERSION=v1.35.3
```

7. Upload the built image to OpenStack if you built it using anything else than the OpenStack builder:

```bash
openstack image create "ubuntu-2404-kube-v1.35.3" \
  --progress \
  --disk-format qcow2 \
  --property os_type=linux \
  --property os_distro=ubuntu2404 \
  --file output/ubuntu-2404-kube-v1.35.3/ubuntu-2404-kube-v1.35.3
```

8. Create a SSH keypair:

```bash
openstack keypair create --type ssh k8s-devstack01
```

Take a note of that the private SSH key and store it somewhere safe.

9. Install needed CAPO prerequisites and generate cluster manifests:

Make sure you've prepared your `clouds.yaml` accordingly. Copy the bundled template and fill in your DevStack credentials:

```bash
cp clouds.yaml.example clouds.yaml
# then edit clouds.yaml and set auth_url, username, password, project_name, project_id, user_domain_name, region_name, identity_api_version
```

The real `clouds.yaml` is gitignored so credentials don't get committed.

Use the `env.rc` utility script to export a common set of environment variables to be used with `clusterctl init` later on.

```bash
wget https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-openstack/master/templates/env.rc -O /tmp/env.rc
source /tmp/env.rc clouds.yaml openstack
```

Export more environment variables that we'll need to define the workload cluster:

```bash
export KUBERNETES_VERSION=v1.35.3
export OPENSTACK_DNS_NAMESERVERS=1.1.1.1
export OPENSTACK_FAILURE_DOMAIN=nova
export OPENSTACK_CONTROL_PLANE_MACHINE_FLAVOR=m1.medium
export OPENSTACK_NODE_MACHINE_FLAVOR=m1.medium
export OPENSTACK_IMAGE_NAME=ubuntu-2404-kube-v1.35.3
export OPENSTACK_SSH_KEY_NAME=k8s-devstack01
export OPENSTACK_EXTERNAL_NETWORK_ID=<ID>
export CLUSTER_NAME=k8s-devstack01
export CONTROL_PLANE_MACHINE_COUNT=3
export WORKER_MACHINE_COUNT=3
```

_Please note that you'll need to fetch the `public` network ID and add it to the `OPENSTACK_EXTERNAL_NETWORK_ID` environment variable. Also the flavor needs to have at least 2 cores otherwise `kubeadm` will fail, this can be ignored from a `kubeadm` perspective but that's not covered here._

10. Generate the cluster manifests and apply them in the `minikube` cluster:

```bash
clusterctl generate cluster k8s-devstack01 --infrastructure openstack > k8s-devstack01.yaml
kubectl apply -f k8s-devstack01.yaml
```

_The checked-in `k8s-devstack01.yaml` is a reference of what this tutorial expects: CAPI core kinds on `v1beta2`, kube-proxy disabled via `KubeadmControlPlane.spec.kubeadmConfigSpec.clusterConfiguration.proxy.disabled: true`, and Cilium-appropriate security-group rules (udp/8472, tcp/4240, ICMP) on `OpenStackCluster`. If you re-generate with a different `clusterctl` version, port those edits back in before applying._

11. Check the status of the cluster using `clusterctl`, also check the logs of, primarily, the `capo-controller`:

```bash
clusterctl describe cluster k8s-devstack01
NAME                                                               READY  SEVERITY  REASON  SINCE  MESSAGE
Cluster/k8s-devstack01                                             True                     14m
├─ClusterInfrastructure - OpenStackCluster/k8s-devstack01
└─ControlPlane - KubeadmControlPlane/k8s-devstack01-control-plane  True                     14m
  └─Machine/k8s-devstack01-control-plane-zkjdn                     True                     15m
```

12. Download the cluster kubeconfig and test connectivity:

```bash
clusterctl get kubeconfig k8s-devstack01 > k8s-devstack01.kubeconfig
export KUBECONFIG=$PWD/k8s-devstack01.kubeconfig
```

You should now be able to reach the cluster running within the DevStack environment! 🎉

Nodes will be `NotReady` at this point — that's expected: we've asked kubeadm to skip kube-proxy, and we haven't installed a CNI yet. The next step fixes it.

13. Bootstrap the pod network with Flannel (temporary, so ArgoCD can run):

```bash
kubectl apply -f argocd/flannel.yaml
kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=5m
kubectl get nodes
```

Nodes should go `Ready`. You should see **no** `kube-proxy` DaemonSet in `kube-system` — that proves the kubeadm-level `proxy.disabled: true` took effect.

14. Install the OpenStack Cloud Provider:

```bash
git clone --depth=1 https://github.com/kubernetes-sigs/cluster-api-provider-openstack.git
```

Generate the external cloud provider configuration with the provided helper script:

```bash
./cluster-api-provider-openstack/templates/create_cloud_conf.sh clouds.yaml openstack > /tmp/cloud.conf
```

_Note that if you want support for creating `Service` of `type: LoadBalancer` you'll need to configure this in the `cloud.conf` and re-create the secret._

Create the needed secret:

```bash
kubectl create secret -n kube-system generic cloud-config --from-file=/tmp/cloud.conf
```

Create the needed Kubernetes resources for the OpenStack cloud provider:

```bash
helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack
helm repo update
helm upgrade --install \
  openstack-ccm cpo/openstack-cloud-controller-manager \
  --namespace kube-system \
  --version 2.35.0 \
  --values occm-values.yaml
```

OCCM clears the `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` taint on each node.

15. Install ArgoCD:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version 9.5.11
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
```

16. Apply the ArgoCD app-of-apps — this installs Cilium (sync wave 0) and the Flannel-cleanup Job (sync wave 1):

First, substitute the control-plane endpoint host into `argocd/apps/cilium-app.yaml`:

```bash
API_ENDPOINT=$(kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://##; s#:.*##')
sed -i "s/REPLACE_WITH_CONTROL_PLANE_ENDPOINT_HOST/${API_ENDPOINT}/" \
  argocd/apps/cilium-app.yaml
```

Then apply the root Application:

```bash
kubectl apply -f argocd/root-app.yaml
```

_Note: commit the sed'd `cilium-app.yaml` back to Git (or set the value via your own values-override repo) so ArgoCD's own reconciliation doesn't flip it back. For a local tutorial the local edit is fine — ArgoCD reads it from this repo's `main` branch via the root app, so if you want drift-free steady state you need a branch/fork with the real endpoint._

17. Watch the migration happen:

```bash
# Cilium installs first
argocd app get cilium
kubectl -n kube-system rollout status ds/cilium --timeout=10m

# Then cni-migration runs
argocd app get cni-migration
kubectl -n kube-system logs job/cni-migration -f
```

Expected final state:

```bash
kubectl get ns kube-flannel      # -> not found
kubectl -n kube-system get ds    # -> cilium only (no kube-proxy, no kube-flannel-ds)
cilium status                    # -> KubeProxyReplacement: True
helm ls -n kube-system           # -> cilium release present (now owned by ArgoCD)
kubectl get pods -A -o wide      # -> all pods Running on 192.168.0.0/16, now via Cilium
```

18. Done! 🚀

From now on, Cilium is managed via Git: bump `targetRevision` in `argocd/apps/cilium-app.yaml` to roll a new version, or edit `argocd/cilium-values.yaml` to change values. ArgoCD picks up the commit and syncs.

## Bonus: no static per-cluster OpenStack password ("secret0")

Steps 1-18 above still use a hand-filled `clouds.yaml` with a real
username/password (step 9) — fine for a first walkthrough, but it's exactly
the pattern ("one OpenStack user account per cluster, password that never
expires") a real platform shouldn't do long-term. This section swaps that
static credential for one minted on demand, short-lived, by
[OpenBao](https://openbao.org/) + VEXXHOST's
[`vault-plugin-secrets-openstack`](https://github.com/vexxhost/vault-plugin-secrets-openstack),
delivered via [External Secrets Operator](https://external-secrets.io/)'s
`VaultDynamicSecret` generator, consumed by CAPO's
[`OpenStackClusterIdentity`](https://cluster-api-openstack.sigs.k8s.io/topics/openstack-cluster-identity).
One narrowly-scoped static credential remains at the root (OpenBao's own
root identity) — everything downstream is ephemeral.

19. Create one narrowly-scoped project + root user in DevStack — this is
    the *one* static credential left in the whole chain, deliberately
    scoped to nothing beyond what it needs:

    ```bash
    source /opt/stack/devstack/openrc admin admin   # on the devstack VM
    openstack project create capo-poc
    openstack user create vault-broker --password '<pick one>' --project capo-poc
    openstack role add --user vault-broker --project capo-poc member
    ```

20. Deploy OpenBao and the OpenStack secrets engine:

    ```bash
    kubectl apply -f openbao/
    kubectl -n openbao rollout status deploy/openbao --timeout=120s

    OS_AUTH_URL="http://<devstack-ip>/identity/v3" \
    VAULT_BROKER_USER_ID="$(openstack user show vault-broker -f value -c id)" \
    VAULT_BROKER_PASSWORD='<the password from step 19>' \
    CAPO_POC_PROJECT_ID="$(openstack project show capo-poc -f value -c id)" \
    MEMBER_ROLE_ID="$(openstack role show member -f value -c id)" \
    ./openbao/setup.sh
    ```

    Sanity check it mints a real, working credential before moving on:

    ```bash
    POD=$(kubectl -n openbao get pod -l app=openbao -o jsonpath='{.items[0].metadata.name}')
    kubectl -n openbao exec "$POD" -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$(cat /tmp/openbao-root-token.txt)" \
      bao read openstack/creds/capo-poc-member
    ```

21. Install External Secrets Operator:

    ```bash
    helm repo add external-secrets https://charts.external-secrets.io
    helm upgrade --install external-secrets external-secrets/external-secrets \
      -n external-secrets --create-namespace --set installCRDs=true
    ```

22. Apply the consumer side — generator, `ExternalSecret`,
    `OpenStackClusterIdentity`, and a minimal infra-only `OpenStackCluster`/
    `Cluster` (no `MachineDeployment`/control plane on purpose — this
    proves the credential path, not a bootable node):

    ```bash
    kubectl apply -f capo-poc/
    kubectl -n capo-poc get externalsecret capo-poc-clouds   # STATUS: SecretSynced
    kubectl -n capo-poc get openstackcluster capo-poc -o wide   # READY: true
    ```

    `capo-controller` reconciles the network/subnet/router/security-group
    using a credential that, at the time it's used, is seconds old. Watch
    it rotate:

    ```bash
    watch kubectl -n capo-poc get secret capo-poc-clouds -o jsonpath='{.data.clouds\.yaml}' \
      -o go-template='{{index .data "clouds.yaml" | base64decode}}'
    ```

    The `application_credential_id` embedded in the Secret changes every
    `refreshInterval` (60s in `capo-poc/01-external-secret.yaml`, comfortably
    under the 300s lease TTL in `openbao/setup.sh`); old credentials
    disappear from `openstack application credential list --user vault-broker`
    once their lease expires — Vault/OpenBao revokes them in Keystone, not
    just locally.

23. To go further: swap the minimal `OpenStackCluster` for a full
    `Cluster`+`KubeadmControlPlane`+`MachineDeployment` (steps 6-12 above,
    minus the `clouds.yaml` step — point `identityRef` at the
    `OpenStackClusterIdentity` from step 22 instead) once you've built a
    real node image, and this whole tutorial runs with zero static,
    non-expiring OpenStack credentials anywhere except the one root
    identity from step 19. `k8s-devstack01/` in this repo is exactly that:
    the step-23 variant of the tutorial's kubeadm path, dynamic credential
    included, 1 control-plane + 1 worker.

    **Gotcha if `apiServerLoadBalancer.enabled: true`:** `capo-poc`'s
    infra-only `OpenStackCluster` never creates an Octavia load balancer, so
    it never noticed this — but `capo-controller`'s reconcile holds one
    authenticated client for the whole reconcile, including its internal
    LB active-wait poll (~2min observed on this DevStack). The original
    120s lease TTL in `openbao/setup.sh` was too close to that window —
    Vault could revoke the credential mid-poll, failing with a confusing
    404 `Could not find Application Credential` instead of a clean retry.
    Bumped to 300s for this reason; if your Octavia is slower, go higher.

## Bonus: Talos instead of kubeadm

An alternative bootstrap path — [Talos Linux](https://www.talos.dev/) instead
of kubeadm, via [Cluster API Bootstrap Provider Talos
(CABPT)](https://github.com/siderolabs/cluster-api-bootstrap-provider-talos)
and [Cluster API Control Plane Provider Talos
(CACPPT)](https://github.com/siderolabs/cluster-api-control-plane-provider-talos).
Kept separate from the main walkthrough (`talos-devstack01/`, own namespace,
own OpenBao roleset) — it doesn't replace steps 1-23 above, it's a sibling
that reuses the same OpenBao/ESO dynamic-credential chain from the secret0
bonus section.

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

24. Install the Talos providers. `clusterctl`'s built-in provider registry
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

25. Get a Talos node image — no `image-builder` needed. Talos publishes
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

26. Apply `talos-devstack01/` — same shape as `k8s-devstack01/` (namespace,
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

27. Watch it come up — CAPO reconciles network/subnet/router/load balancer
    exactly like `capo-poc`, then CACPPT creates the control-plane Machine
    once the OpenStackCluster is `Ready`:

    ```bash
    kubectl -n talos-devstack01 get cluster,openstackcluster,taloscontrolplane,machines
    ```

    This is a minimal smoke test (1 control-plane + 1 worker, no
    `configPatches`) — it proves the Talos providers and image work against
    this DevStack, not a steady-state cluster. No OCCM/CNI/ArgoCD migration
    wired up for it; that's the kubeadm path's job (steps 13-18).
