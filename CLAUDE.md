# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is a **tutorial repository**, not a software project. It has no build, lint, or test commands, no CI, and no source code. The `README.md` is an 18-step walkthrough for running Cluster API (CAPI) + Cluster API Provider OpenStack (CAPO) locally on top of a DevStack KVM install, using minikube as the management cluster. The workload cluster is stood up kube-proxy-free, then Cilium is installed by ArgoCD, then Flannel (the bootstrap CNI) is automatically removed by a Job. The repo exists to hold sample config files referenced by the README; treat `README.md` as the source of truth.

## What lives here

- `README.md` — the walkthrough. Numbered steps 1–18.
- `cloud.conf` — sample in-cluster OpenStack cloud-provider config. In step 14 it is turned into a `cloud-config` Secret in `kube-system` via `kubectl create secret generic cloud-config --from-file=/tmp/cloud.conf`. The `[LoadBalancer]` section must be set here for `Service` `type: LoadBalancer` support; changing it requires recreating the Secret.
- `occm-values.yaml` — Helm values for the `cpo/openstack-cloud-controller-manager` chart (step 14). Enables controllers `cloud-node`, `cloud-node-lifecycle`, `route`, `service`; sets `secret.name: cloud-config` with `secret.create: false` (expects the Secret above to exist already); pins `cluster.name: k8s-devstack01`; schedules on control-plane nodes only.
- `clouds.yaml.example` — blank template for the `openstack` client auth config. The user copies this to `clouds.yaml` (gitignored) and fills in real DevStack credentials. Consumed by the upstream `env.rc` helper (fetched at step 9) to export `OPENSTACK_*` env vars used by `clusterctl generate cluster`.
- `k8s-devstack01.yaml` — reference manifest for the workload cluster. CAPI core kinds (`Cluster`, `MachineDeployment`, `KubeadmControlPlane`, `KubeadmConfigTemplate`) are on `v1beta2` with `apiGroup:`-only `ContractVersionedObjectReference` refs. CAPO kinds (`OpenStackCluster`, `OpenStackMachineTemplate`) stay on `v1beta1` (CAPO v0.14 still serves v1beta1 as primary). Hand-edits vs. `clusterctl generate cluster` today: `KubeadmControlPlane.spec.kubeadmConfigSpec.clusterConfiguration.proxy.disabled: true` (disables kube-proxy addon so Cilium can own it), and `OpenStackCluster.spec.managedSecurityGroups.allNodesSecurityGroupRules` replaced with Cilium-appropriate rules (udp/8472 VXLAN, tcp/4240 health, ICMP).
- `argocd/flannel.yaml` — pinned Flannel `v0.28.4` manifest, `net-conf.json.Network` rewritten to `192.168.0.0/16` so it matches `Cluster.spec.clusterNetwork.pods.cidrBlocks`. Applied once in step 13 so ArgoCD has a pod network. Deleted automatically by `argocd/cni-migration/job.yaml` once Cilium is Ready.
- `argocd/cilium-values.yaml` — single source of truth for Cilium Helm values. Used at bootstrap via `$values` in the ArgoCD multi-source Application; not Helm-installed directly. Sets `kubeProxyReplacement: true`, `cni.exclusive: true` (removes Flannel's CNI config per-node), `ipam` cluster-pool CIDR to match the cluster pod CIDR, VXLAN tunnel with MTU 1450.
- `argocd/root-app.yaml` — ArgoCD app-of-apps pointing at `argocd/apps/`. Applied once in step 16.
- `argocd/apps/cilium-app.yaml` — Cilium `Application` (sync wave 0). Multi-source: `helm.cilium.io` chart `cilium` `1.19.3` + this repo for `$values/argocd/cilium-values.yaml`. Contains a `REPLACE_WITH_CONTROL_PLANE_ENDPOINT_HOST` placeholder that step 16 sed-replaces with the actual API-server floating IP (Cilium needs direct reachability for kube-proxy-replacement to bootstrap).
- `argocd/apps/cni-migration-app.yaml` — `Application` (sync wave 1) pointing at `argocd/cni-migration/`. `selfHeal: false` + `prune: false` so the Job runs exactly once and isn't re-applied.
- `argocd/cni-migration/rbac.yaml` — ServiceAccount `cni-migration` in `kube-system` plus a ClusterRole with cluster-scoped delete on `namespaces`, `clusterroles`, `clusterrolebindings`, `daemonsets`, and rollout-restart permissions on `deployments` / `statefulsets`. Scoped intentionally broad for a tutorial.
- `argocd/cni-migration/job.yaml` — one-shot Job that polls `ds/cilium.status.numberReady == desiredNumberScheduled`, then deletes the `kube-flannel` namespace + flannel cluster RBAC, then `kubectl rollout restart` on all `deployments` / `statefulsets` in `kube-system` and `argocd` so existing (Flannel-era) pods re-IP via Cilium. Uses `bitnami/kubectl:1.35`.
- `.gitignore` — keeps the real `clouds.yaml` and any `*.kubeconfig` out of git.
- `LICENSE` — Apache 2.0.

External scripts referenced by the README but not vendored: `templates/env.rc` and `templates/create_cloud_conf.sh` from the upstream `cluster-api-provider-openstack` repo.

## End-to-end flow at a glance

DevStack on KVM (separate repo) → minikube management cluster on the `devstack_net` KVM network → `clusterctl init --infrastructure openstack` (preceded by `CLUSTER_TOPOLOGY=true` and applying the ORC `install.yaml --server-side`) → build a node image with `image-builder` (qemu) and upload to OpenStack → prepare `clouds.yaml`, `source env.rc`, export remaining `OPENSTACK_*` and `CLUSTER_NAME=k8s-devstack01` vars → `clusterctl generate cluster … > k8s-devstack01.yaml` and `kubectl apply` (kubeadm skips kube-proxy via `proxy.disabled: true`) → `clusterctl describe cluster` / `clusterctl get kubeconfig` → **step 13: `kubectl apply -f argocd/flannel.yaml`** (nodes go Ready on a temporary Flannel overlay) → install OpenStack CCM via Helm using `occm-values.yaml` (after creating the `cloud-config` Secret from `cloud.conf`) → **step 15: `helm upgrade --install argocd argo/argo-cd`** → **step 16: sed-replace `REPLACE_WITH_CONTROL_PLANE_ENDPOINT_HOST` in `argocd/apps/cilium-app.yaml` with the API-server floating IP, then `kubectl apply -f argocd/root-app.yaml`** → ArgoCD syncs wave 0 (Cilium with `kubeProxyReplacement: true`, `cni.exclusive: true`) then wave 1 (the cleanup Job deletes Flannel and rolling-restarts `kube-system` + `argocd` workloads so they re-IP via Cilium). Steady state: Cilium is ArgoCD-owned; Flannel + kube-proxy never run in steady state.

## Repo-specific conventions worth knowing

- Cluster name is `k8s-devstack01` throughout. If renamed, update `occm-values.yaml` (`cluster.name`), every `CLUSTER_NAME` export, the generated manifest filename, and the `clusterctl` invocations in the README.
- `occm-values.yaml` sets `secret.create: false` — the `cloud-config` Secret must be created out-of-band before `helm upgrade --install`.
- OpenStack flavor must have ≥2 cores or `kubeadm` fails (step 9 note).
- `clusterctl init` installs `cert-manager`; this can collide with an existing install.
- **Pod CIDR alignment**: `Cluster.spec.clusterNetwork.pods.cidrBlocks: [192.168.0.0/16]` is duplicated in two other places — `argocd/flannel.yaml` (`net-conf.json.Network`) and `argocd/cilium-values.yaml` (`ipam.operator.clusterPoolIPv4PodCIDRList`). If the cluster CIDR changes, all three must change together.
- **Cilium endpoint host**: `argocd/apps/cilium-app.yaml` carries a `REPLACE_WITH_CONTROL_PLANE_ENDPOINT_HOST` placeholder filled in at step 16 (API-server floating IP, needed for Cilium's kube-proxy replacement to reach the apiserver before eBPF services are loaded). If the cluster is torn down and rebuilt, the floating IP changes and the file must be re-sed'd (or the commit reverted first).
- **CNI migration sequencing**: Flannel is bootstrap-only — don't deploy workloads before the `cni-migration` Job succeeds. The Job restarts every non-hostNetwork pod in `kube-system` and `argocd`; any user workload with Flannel-era IPs would need the same treatment.
- **CAPI v1beta2 + CAPO v1beta1**: `k8s-devstack01.yaml` mixes API versions. CAPI core refs use `apiGroup:` (ContractVersionedObjectReference); the CAPO-pointing refs on `Cluster.spec.infrastructureRef`, `MachineDeployment.spec.template.spec.infrastructureRef`, and `KubeadmControlPlane.spec.machineTemplate.infrastructureRef` also use `apiGroup:` (CAPI v1beta2 looks up the current served version via the provider's CRD). Don't re-add `apiVersion:` to any ref in a v1beta2 kind.

## Editing guidance

There is no in-repo validation. Changes to `cloud.conf` or `occm-values.yaml` only take effect by re-running the corresponding README step (re-creating the Secret, re-running `helm upgrade --install`). When adjusting these files, cite the README step number rather than duplicating the command blocks.
