#!/usr/bin/env bash
# One-shot OpenBao init/config for the secret0 broker PoC.
# Re-run in full whenever the openbao pod's emptyDir storage is lost
# (pod reschedule, deployment restart) — this is a throwaway local PoC,
# not meant to survive restarts.
set -euo pipefail

: "${OS_AUTH_URL:?set to devstack keystone v3 url, e.g. http://192.168.11.77/identity/v3}"
: "${VAULT_BROKER_USER_ID:?set to the vault-broker OpenStack user id}"
: "${VAULT_BROKER_PASSWORD:?set to the vault-broker OpenStack password}"
: "${CAPO_POC_PROJECT_ID:?set to the capo-poc OpenStack project id}"
: "${MEMBER_ROLE_ID:?set to the OpenStack 'member' role id}"

POD=$(kubectl -n openbao get pod -l app=openbao -o jsonpath='{.items[0].metadata.name}')
bexec() { kubectl -n openbao exec "$POD" -- env BAO_ADDR=http://127.0.0.1:8200 "$@"; }
bexec_i() { kubectl -n openbao exec -i "$POD" -- env BAO_ADDR=http://127.0.0.1:8200 "$@"; }

if bexec bao status -format=json 2>/dev/null | grep -q '"initialized": true'; then
  echo "already initialized — this script only handles first-time setup, aborting" >&2
  exit 1
fi

INIT_JSON=$(bexec bao operator init -key-shares=1 -key-threshold=1 -format=json)
UNSEAL_KEY=$(echo "$INIT_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
ROOT_TOKEN=$(echo "$INIT_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['root_token'])")
echo -n "$ROOT_TOKEN" > /tmp/openbao-root-token.txt
echo "root token + unseal key written to /tmp (local PoC only, not for real use)"

bexec bao operator unseal "$UNSEAL_KEY"

SHA256=$(bexec sha256sum /openbao/plugins/vault-plugin-secrets-openstack | awk '{print $1}')
bexec env BAO_TOKEN="$ROOT_TOKEN" bao write sys/plugins/catalog/secret/vault-plugin-secrets-openstack \
  sha_256="$SHA256" command="vault-plugin-secrets-openstack"

bexec env BAO_TOKEN="$ROOT_TOKEN" bao secrets enable -path=openstack -plugin-name=vault-plugin-secrets-openstack plugin
# 300s, not the original 120s: CAPO's OpenStackCluster reconciler holds one
# authenticated client for the whole reconcile, including its internal
# Octavia load-balancer active-wait poll (~2min observed). At 120s the
# credential's lease could expire mid-poll — Vault revokes the application
# credential out from under the live reconcile, which then fails with a
# confusing 404 "Could not find Application Credential" instead of a clean
# retry. 300s gives every reconcile attempt a comfortable margin.
bexec env BAO_TOKEN="$ROOT_TOKEN" bao write openstack/config/lease ttl=300
bexec env BAO_TOKEN="$ROOT_TOKEN" bao write openstack/config/auth \
  auth_url="$OS_AUTH_URL" \
  user_id="$VAULT_BROKER_USER_ID" \
  password="$VAULT_BROKER_PASSWORD" \
  user_domain_name=""

bexec_i env BAO_TOKEN="$ROOT_TOKEN" bao write openstack/roleset/capo-poc-member \
  project_id="$CAPO_POC_PROJECT_ID" \
  roles=- <<EOF
[{"id":"$MEMBER_ROLE_ID"}]
EOF

# Kubernetes auth so ESO authenticates to OpenBao with its own ServiceAccount
# token — no static token stored anywhere for this leg either.
bexec env BAO_TOKEN="$ROOT_TOKEN" bao auth enable kubernetes
bexec env BAO_TOKEN="$ROOT_TOKEN" bao write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"

bexec_i env BAO_TOKEN="$ROOT_TOKEN" bao policy write capo-poc-read - <<'EOF'
path "openstack/creds/*" {
  capabilities = ["read"]
}
EOF

bexec env BAO_TOKEN="$ROOT_TOKEN" bao write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=capo-poc-read \
  ttl=1h

# cluster-bootstrapper: write-only roleset creation, used by every
# per-cluster chart release's pre-install Job (templates/cluster-chart/
# templates/vault-roleset-job.yaml) and by hand-applied clusters (e.g.
# talos-devstack01/01-roleset-job.yaml). Deliberately narrower than "eso"
# above — can create/update rolesets, cannot read any credential.
bexec_i env BAO_TOKEN="$ROOT_TOKEN" bao policy write cluster-bootstrapper-write - <<'EOF'
path "openstack/roleset/*" {
  capabilities = ["create", "update"]
}
EOF

bexec env BAO_TOKEN="$ROOT_TOKEN" bao write auth/kubernetes/role/cluster-bootstrapper \
  bound_service_account_names=cluster-bootstrapper \
  bound_service_account_namespaces="*" \
  policies=cluster-bootstrapper-write \
  ttl=1h

echo "done"
