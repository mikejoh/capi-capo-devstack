# Least-privilege OpenStack credentials for cluster provisioning

Design notes from a working session, condensed. Static credentials, no Vault/OpenBao —
see the [secret0 bonus section](../README.md#bonus-no-static-per-cluster-openstack-password-secret0)
for the dynamic-credential alternative and why we're deliberately not using it yet.

## The problem

Provisioning a new cluster needs: a **Project**, a **User**, that user's project
**RBAC-shared onto the external network**, a **quota**, and a per-cluster
**Application Credential** to hand to CAPO. Every one of those five actions is
**admin-only by default OpenStack policy** — there's no built-in role that bundles
just this set. The goal: a "root" provisioning credential that can do exactly
these five things and nothing else, not a disguised cloud-admin.

## Policy: one role, seven overrides

New role `cluster-provisioner`, granted **system-scoped**
(`openstack role add --user <provisioner> --system all cluster-provisioner`) —
project scope isn't enough, creating projects/users is cross-project work.

```yaml
# /etc/keystone/policy.yaml
"identity:create_project": "role:cluster-provisioner or rule:admin_required"
"identity:create_user":    "role:cluster-provisioner or rule:admin_required"
"identity:create_grant":   "role:cluster-provisioner or rule:admin_required"
"identity:update_user":    "role:cluster-provisioner or rule:admin_required"
"identity:create_application_credential": "role:cluster-provisioner or rule:owner"
```

`identity:update_user` is for **resetting the per-cluster user's password on
each rotation cycle** (see Q1/Q3) — root can never mint that user's
application credential directly (hard limit below), so rotation works by
resetting the password, having the user self-bootstrap a new credential, then
rotating the password away again. `identity:create_application_credential`'s
override barely matters in practice given the hard limit below — self-service
creation (`rule:owner`) was already the default — kept for completeness/documentation.
```yaml
# /etc/neutron/policy.yaml
"create_rbac_policy": "role:cluster-provisioner or rule:admin_or_owner"
"update_quota":       "role:cluster-provisioner or rule:admin_only"
```
```yaml
# /etc/nova/policy.yaml
"os_compute_api:os-quota-sets:update": "role:cluster-provisioner or rule:admin_api"
```

**The `or rule:...` matters.** oslo.policy replaces the whole check string for a
key — it doesn't OR with the built-in default. Drop the `or` and real cloud-admins
lose access to these same actions too. Restart keystone/neutron/nova after editing.
Default rule names vary by OpenStack release — verify against your actual
policy-in-code defaults before applying blind.

## Per-cluster provisioning

**Declarative, via ORC CRDs** — covers 3 of the 5 actions. `Project` and `User`
use the **root** credential as `cloudCredentialsRef`; `ApplicationCredential`
must use the **per-cluster user's own** credentials instead (see hard limits
below — root can never do this step, for any user but itself):

```yaml
apiVersion: openstack.k-orc.cloud/v1alpha1
kind: Project
metadata: {name: <cluster>, namespace: <cluster>}
spec:
  cloudCredentialsRef: {secretName: root-creds, cloudName: openstack}
  managementPolicy: managed
  resource: {name: <cluster>}
---
apiVersion: openstack.k-orc.cloud/v1alpha1
kind: User
metadata: {name: <cluster>-user, namespace: <cluster>}
spec:
  cloudCredentialsRef: {secretName: root-creds, cloudName: openstack}
  managementPolicy: managed
  resource:
    name: <cluster>-user
    defaultProjectRef: <cluster>
    passwordRef: <cluster>-user-bootstrap-password   # root-generated, see Q1 below — cannot be omitted
---
apiVersion: openstack.k-orc.cloud/v1alpha1
kind: ApplicationCredential
metadata: {name: <cluster>-appcred, namespace: <cluster>}
spec:
  # MUST be this user's OWN credentials, not root — Keystone hard-blocks
  # cross-user ApplicationCredential creation unconditionally, no policy
  # escape hatch exists. See "Hard limits" below.
  cloudCredentialsRef: {secretName: <cluster>-user-bootstrap-clouds, cloudName: openstack}
  managementPolicy: managed
  resource:
    name: <cluster>-appcred
    userRef: <cluster>-user   # same user as cloudCredentialsRef above — self-service only
    unrestricted: false
    expiresAt: "2027-01-01T00:00:00Z"
    # roleRefs omitted: defaults to whatever roles the calling token carries
    secretRef: <cluster>-clouds   # pre-create this Secret empty w/ a "value" key — see below
```

**Role assignment: also covered by ORC, but not yet in a release you can install.**
A `RoleAssignment` kind (`userRef`/`groupRef` + `projectRef`/`domainRef` +
`roleRef` — exactly `identity:create_grant`) was merged to `main` on
2026-07-08. It's not in any tagged release yet — latest tag is `v2.6.0`
(2026-06-10, predates it), and the version actually running in this cluster is
`v2.5.0` (April) — even older. Once it ships in a release, add:

```yaml
apiVersion: openstack.k-orc.cloud/v1alpha1
kind: RoleAssignment
metadata: {name: <cluster>-user-member, namespace: <cluster>}
spec:
  cloudCredentialsRef: {secretName: root-creds, cloudName: openstack}
  managementPolicy: managed
  resource:
    userRef: <cluster>-user
    projectRef: <cluster>
    roleRef: member
```

**Scripted (one-shot Jobs, same shape as `openbao/01-roleset-job.yaml`)** — the
2 actions still uncovered by any ORC CRD (no `rbacpolicy` or `quota` kind
exists). Real, runnable templates in [`../provisioning/`](../provisioning/):
`01-network-rbac-job.yaml` (checks before creating — the underlying Neutron
API isn't idempotent) and `02-quota-job.yaml` (idempotent `PUT`). The root
credential for these two **can** be an Application Credential — the "app-cred
can't create app-cred" restriction below is Keystone-specific to
`create_application_credential`, it doesn't apply to Neutron/Nova quota or
RBAC calls.

## Bridging the gap: ORC's ApplicationCredential → a usable clouds.yaml

`ApplicationCredential.spec.resource.secretRef` only writes the raw credential
**string** (key `value`) into the target Secret — the credential's `id` lives
on the CR's `.status.id` (not sensitive, just an identifier). Neither one
alone is a usable `clouds.yaml`. Verified live this session: read both, write
a third Secret combining them:

```bash
APPCRED_ID=$(kubectl get applicationcredential <name> -o jsonpath='{.status.id}')
APPCRED_SECRET=$(kubectl get secret <raw-secret> -o jsonpath='{.data.value}' | base64 -d)
# → clouds.yaml: auth.application_credential_id = $APPCRED_ID,
#                auth.application_credential_secret = $APPCRED_SECRET,
#                auth_type = v3applicationcredential
```

Confirmed by actually authenticating with the assembled `clouds.yaml`
(`openstack token issue` returned a real token). Automated as
[`../provisioning/03-materialize-clouds-job.yaml`](../provisioning/03-materialize-clouds-job.yaml)
— waits for the `ApplicationCredential` to go `Available`, then patches the
target Secret. Needs the target Secret pre-created (empty) too, same reason as
`secretRef` above: this Job's own RBAC only grants `update`/`patch` on it by
name, not `create` (Kubernetes RBAC can't scope `create` by `resourceName` —
the object doesn't exist yet at authorization time, so a `create` grant here
would have to be unrestricted-by-name instead).

## ORC operational gotchas (found by testing live, not from docs)

- `secretRef`/`passwordRef`-style fields expect a Secret **you pre-create** — ORC's
  own RBAC (`orc-manager-role`) only grants `get,list,patch,update,watch` on
  `secrets`, **no `create`**. Pre-create it empty; for `ApplicationCredential` it
  must contain a `value` key (the secret string you're assigning — Keystone lets
  you supply this instead of letting it generate one).
- `spec.resource` is **immutable** once set on any managed ORC object — a bad
  first attempt means delete-and-recreate, not edit.
- `*Ref` fields (`userRef`, `roleRefs`, `domainRef`) point at **other ORC CRs**,
  not raw OpenStack names/IDs. To reference something ORC didn't create, import
  it: `managementPolicy: unmanaged` + `spec.import.id: <existing-id>`.
  **Use `import.id`, not `import.filter.name`/list-based lookups** — `list_*`
  Keystone calls (e.g. `identity:list_users`) are admin-only by default even when
  the equivalent single-object `get_*` call allows self-access.

## Hard limits found live, not in any doc

**1. A token obtained via an application credential can never create another
application credential** — Keystone hard-codes this
(`"Using method 'application_credential' is not allowed for managing additional
application credentials."`), it's not a policy setting and cannot be overridden.
This means: **the root/provisioning credential must itself be password-based (or
some other non-app-cred auth), never an application credential**, if its job
includes minting per-cluster `ApplicationCredential`s.

**2. Bigger limit, supersedes what this doc originally said: nobody can ever
create an application credential for a different user than the one they're
authenticated as — not a policy setting either, and not even bypassable by
admin.** Verified directly in Keystone source
(`keystone/api/users.py`, `POST /v3/users/{user_id}/application_credentials`):

```python
ENFORCER.enforce_call(action='identity:create_application_credential')
...
if self.oslo_context.user_id != user_id:
    raise ForbiddenAction('Cannot create an application credential for another user.')
```

The oslo.policy check runs first (that's the part our `role:cluster-provisioner
or rule:owner` override affects) — but right after, Keystone does an
**unconditional, hardcoded `user_id` comparison** with no policy escape hatch at
all. Confirmed live: a `test-provisioner` token carrying `cluster-provisioner`
system-wide got exactly this 403 attempting to create a credential for a
different user, despite the policy override being in place and working (it did
get past the `identity:create_application_credential` check — this is a
*different*, later check in the same code path).

This means our earlier live "success" (`vault-broker-import` +
`vault-broker-test-appcred`) never actually tested cross-user creation — it
only worked because it was accidentally self-referential: the credentials used
to authenticate (`vault-broker-password-creds`) and the `userRef` target both
resolved to the same Keystone user (`vault-broker`). Same-user self-service
creation was always going to succeed regardless of any of this — that's the
default `rule:owner` behavior, no override needed.

## Q1: where does the per-cluster user's password go? Fire-and-forget?

Partially yes, corrected from an earlier version of this doc that assumed
cross-user `ApplicationCredential` creation was possible with the right policy
— it isn't, per the hard limit above. Realistic version:

1. Root credential creates the `User` **with** an initial random password
   (`User.spec.resource.passwordRef`, root-generated, root never needs to read
   it back).
2. A one-time step authenticates **as that user itself** using that password
   and self-mints its own `ApplicationCredential` —
   `cloudCredentialsRef` = the per-cluster user's own credentials, `userRef` =
   itself. Satisfies default `rule:owner`, no policy override needed for this
   specific step.
3. The password can be rotated away to a second random, never-recorded value
   immediately afterward for hygiene — it can be made ephemeral and never seen
   by a human, but it cannot be avoided entirely. `User.spec.resource.passwordRef`
   being optional (*"if not specified, the user is created without a
   password"*) is real, but only usable for identities that will *never*
   self-bootstrap their own application credential — which the per-cluster
   user, by definition, needs to do at least once.

## Q2: Application Credential TTL?

`expiresAt` is an **absolute ISO8601 timestamp**, not a relative duration like a
Vault lease — compute and set the real datetime, no "90 days" shorthand. Omit it
→ never expires. Also available: `roleRefs` (restrict which of the user's roles
the cred carries) and `unrestricted: false` (recommended default — blocks the
cred from minting further creds/trusts; moot for cross-user chaining per the hard
limit above, but still relevant for same-user self-service creation). Rotation
isn't automatic on expiry — plan a scheduled job/GitOps process that replaces the
CR before expiry, using the root credential each time.

## Q3: credential lifecycle

- **Root/provisioning credential**: used rarely (cluster create/destroy/rotate
  only). Must be password-based (hard limit above). Store in a real secrets
  manager *outside* any workload cluster — it provisions clusters, it shouldn't
  live inside one. Rotate on a schedule + immediately on personnel
  change/suspected compromise. Low usage frequency by design — any anomalous
  spike is a strong signal, worth alerting on.
- **Downstream (per-cluster CAPO) credential**: an ORC-managed
  `ApplicationCredential`, `expiresAt` set, landing in `<cluster>-clouds` → same
  `OpenStackClusterIdentity` consumer contract already proven in `capo-poc`.
  Rotate via the same bootstrap dance as creation, not a direct root mint (root
  can never create this user's app-cred directly): root resets the per-cluster
  user's password (`identity:update_user`) → a Job authenticates as that user
  with the new password → self-mints a new `ApplicationCredential` → deletes
  the old one → root resets the password again to a new, never-recorded value.
  Teardown
  on decommission: delete `ApplicationCredential` → `RoleAssignment` (once
  available) → `User` → `Project` CRs (ORC handles those); network-RBAC/quota
  cleanup stays a scripted teardown mirroring the creation Job.

## Bonus finding: does any of this ever need an SSH key?

No. Verified in CAPO source (`api/v1beta2/openstackmachine_types.go`):
`sshKeyName` is `+optional`, `omitempty`, no webhook requires it — pure passthrough
to Nova's optional `key_name` param
(`pkg/cloud/services/compute/instance.go`). kubeadm bootstrap happens entirely via
cloud-init `user_data`, zero SSH involved. The README creates one (step 8) purely
for **operator convenience** (debugging access after boot), not because CAPI/CAPO
needs it. Talos has no SSH daemon at all — `talos-devstack01/04-cluster.yaml`
correctly omits `sshKeyName` everywhere. Rancher/Terraform flows that seemed to
require SSH keys are a different mechanism entirely (those tools actively SSH in
to push files/run install commands themselves) — not an OpenStack/Nova
requirement, a design choice of those specific tools.
