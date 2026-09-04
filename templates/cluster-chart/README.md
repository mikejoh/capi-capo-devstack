# cluster chart

Templated version of `../../capo-poc/`, parameterized so a new cluster is
"copy `clusters/capo-poc-2.yaml`, change the values, commit" instead of
hand-writing manifests. Renders:

- `Namespace` for the cluster
- a pre-install/pre-upgrade `Job` (`vault-roleset-job.yaml`) that creates
  the Vault roleset via OpenBao's HTTP API — a roleset isn't a Kubernetes
  object, so this can't be a plain manifest. Authenticates with the
  shared `cluster-bootstrapper` ServiceAccount (created once in
  `../../openbao/04-rbac.yaml`) against a **write-only** OpenBao role —
  it can create/update rolesets, it cannot read any credential. That's a
  deliberately different, narrower role than the one ESO uses.
- `VaultDynamicSecret` + `ExternalSecret` — same shape as
  `capo-poc/01-external-secret.yaml`, reading `openstack/creds/<cluster>-member`
- `OpenStackClusterIdentity` pointing at the resulting Secret
- a minimal, infra-only `OpenStackCluster`/`Cluster` (no
  `MachineDeployment`/control plane — see step 5 of
  `../../docs/dynamic-openstack-credentials.md` for going further)

## Prerequisites (one-time, not per-cluster)

Already covered by `../../openbao/setup.sh`, but worth restating since
this chart depends on them existing first:

- OpenBao's `eso` kubernetes-auth role + a **glob** policy
  (`openstack/creds/*`, read-only) — one shared role covers every
  cluster's roleset path, nothing to add per cluster.
- OpenBao's `cluster-bootstrapper` kubernetes-auth role + a policy scoped
  to `openstack/roleset/*` with `create`/`update` only (no read/list/delete).
- The `cluster-bootstrapper` ServiceAccount itself, in the `openbao`
  namespace (`../../openbao/04-rbac.yaml`) — shared across every cluster
  release. Don't recreate it per cluster; the chart only references it by
  name.

## Usage

```bash
helm install <cluster-name> . -f ../../clusters/<cluster-name>.yaml
```

Or, once `argocd/apps/clusters-appset.yaml` is wired into the app-of-apps:
add a new `clusters/<name>.yaml`, commit, push — ArgoCD picks it up.

## Known rough edges (PoC-honest, not hidden)

- `openstack.projectId`/`memberRoleId` in every values file currently
  reuse the one `capo-poc` project — matches the project-per-environment
  lean in the planning repo's `area-openstack-tenancy-model.md`. Project
  *per cluster* would additionally need `vault-broker` granted `member`
  on each new project before this chart's Job can succeed — not
  automated here.
- `cluster-bootstrapper`'s OpenBao role binds `bound_service_account_namespaces="*"`
  — any namespace can claim that ServiceAccount name and get
  roleset-write access. Fine for a single-operator local PoC, not fine
  as-is for a shared multi-tenant mgmt cluster; tighten before that.
- No decommissioning path — deleting a cluster's Helm release removes the
  K8s objects but leaves its Vault roleset behind (roleset deletion isn't
  wired into any hook here).
