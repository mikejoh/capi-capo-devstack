# provisioning/

Root-credential Jobs for the parts of per-cluster provisioning that
[ORC](https://github.com/k-orc/openstack-resource-controller) can't do
declaratively yet — see `../docs/least-privilege-openstack-credentials.md` for
the full design and the policy the root credential needs.

Templates, not applied as-is: replace `<cluster>` and `<external-network-id>`
throughout before use (same convention as `../clusters/*.yaml` being reference
values files, not live manifests). Project IDs are no longer hardcoded — the
Jobs that need one look it up live from the ORC `Project` CR.

Ordering uses ArgoCD's `hook`/`sync-wave` annotations, not filename order:
`hook: PreSync`/`PostSync` guarantee a phase regardless of wave number;
`sync-wave` only orders resources *within* the same phase.

## Ordering

1. `00-rbac.yaml` — two ServiceAccounts: `secrets-generator` (needs actual
   `create` on secrets, used only by 01) and `openstack-provisioner`
   (get/patch by name only, used by 02/03/04).
2. `01-generate-secrets-job.yaml` — **PreSync hook**, runs before anything
   else regardless of sync-wave. Creates `<cluster>-appcred-raw` (random
   value) and empty `<cluster>-clouds` — neither ORC nor 04 can `create`
   secrets themselves (RBAC deliberately has no `create`, see the design
   doc), so something has to pre-create them.
3. **Sync-wave 0** (default, no annotation needed): the ORC CRDs —
   `Project`, `User` (with `passwordRef`, not passwordless — see the design
   doc's corrected Q1), `RoleAssignment` (once it ships in a tagged ORC
   release), `Network` (imported), `ApplicationCredential` (must
   authenticate as the per-cluster `User` itself, never root — Keystone
   hard-blocks cross-user application credential creation unconditionally,
   verified against source, no policy override exists for it).
4. **Sync-wave 1**: `02-network-rbac-job.yaml` (shares the external network
   into the project, Neutron RBAC `access_as_external` — checks before
   creating, the underlying API isn't idempotent) and `03-quota-job.yaml`
   (compute + network quota, idempotent `PUT`). Both look up the Project's
   real Keystone ID live via an initContainer rather than a hardcoded value.
5. `04-materialize-clouds-job.yaml` — **PostSync hook**, runs after
   everything above. Bridges the gap ORC leaves: `ApplicationCredential`'s
   `secretRef` only holds the raw credential string, the id lives on
   `.status.id`. Combines both into the real `clouds.yaml` in
   `<cluster>-clouds` — the Secret `OpenStackClusterIdentity` points at.
   Verified live against a real ORC-created Application Credential this
   session.

Root credential (used by 02/03, and by Project/User/RoleAssignment/Network)
can be an Application Credential — the "app-cred can't create app-cred"
restriction is Keystone-specific to `create_application_credential`, doesn't
apply to identity project/user/grant calls or Neutron/Nova quota/RBAC calls.
