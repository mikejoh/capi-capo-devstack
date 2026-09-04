# Dynamic OpenStack credentials with OpenBao (no static "secret0")

Required step in the [main walkthrough](../README.md) (its step 7) — this
tutorial has no hand-filled `clouds.yaml` with a static, non-expiring
OpenStack password anywhere ("one OpenStack user account per cluster,
password that never expires" is exactly the pattern a real platform
shouldn't do long-term). Every OpenStack credential the tutorial uses is
minted on demand, short-lived, by [OpenBao](https://openbao.org/) + VEXXHOST's
[`vault-plugin-secrets-openstack`](https://github.com/vexxhost/vault-plugin-secrets-openstack),
delivered via [External Secrets Operator](https://external-secrets.io/)'s
`VaultDynamicSecret` generator, consumed by CAPO's
[`OpenStackClusterIdentity`](https://cluster-api-openstack.sigs.k8s.io/topics/openstack-cluster-identity).
One narrowly-scoped static credential remains at the root (OpenBao's own
root identity) — everything downstream is ephemeral.

See [least-privilege-openstack-credentials.md](least-privilege-openstack-credentials.md)
for an alternative that keeps a static root credential instead of OpenBao.

1. Create one narrowly-scoped project + root user in DevStack — this is
   the *one* static credential left in the whole chain, deliberately
   scoped to nothing beyond what it needs:

   ```bash
   source /opt/stack/devstack/openrc admin admin   # on the devstack VM
   openstack project create capo-poc
   openstack user create vault-broker --password '<pick one>' --project capo-poc
   openstack role add --user vault-broker --project capo-poc member
   ```

2. Deploy OpenBao and the OpenStack secrets engine:

   ```bash
   kubectl apply -f openbao/
   kubectl -n openbao rollout status deploy/openbao --timeout=120s

   OS_AUTH_URL="http://<devstack-ip>/identity/v3" \
   VAULT_BROKER_USER_ID="$(openstack user show vault-broker -f value -c id)" \
   VAULT_BROKER_PASSWORD='<the password from step 1>' \
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

3. Install External Secrets Operator:

   ```bash
   helm repo add external-secrets https://charts.external-secrets.io
   helm upgrade --install external-secrets external-secrets/external-secrets \
     -n external-secrets --create-namespace --set installCRDs=true
   ```

4. Optional sanity check — apply the consumer side — generator,
   `ExternalSecret`, `OpenStackClusterIdentity`, and a minimal infra-only
   `OpenStackCluster`/`Cluster` (no `MachineDeployment`/control plane on
   purpose — this proves the credential path, not a bootable node). Skip
   this if you're heading straight to the real target, the Talos cluster
   in the main walkthrough's step 9 — that's the same proof, on real
   infrastructure:

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

**Gotcha if `apiServerLoadBalancer.enabled: true`:** `capo-poc`'s
infra-only `OpenStackCluster` never creates an Octavia load balancer, so it
never noticed this — but `capo-controller`'s reconcile holds one
authenticated client for the whole reconcile, including its internal LB
active-wait poll (~2min observed on this DevStack). The original 120s lease
TTL in `openbao/setup.sh` was too close to that window — Vault could revoke
the credential mid-poll, failing with a confusing 404 `Could not find
Application Credential` instead of a clean retry. Bumped to 300s for this
reason; if your Octavia is slower, go higher. This applies to
`talos-devstack01/` too (also `apiServerLoadBalancer.enabled: true`).

Next: back to the [main walkthrough](../README.md), step 8, to get a Talos
node image and apply the real cluster.
