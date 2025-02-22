# CAPI + CAPO + Devstack

Try out your favourite tools locally! :rocket:

This repository shows you step-by-step on how to run a complete environment locally to test Cluster API, Cluster API Provider OpenStack (on `kind`) and a minimal Devstack (local OpenStack).

I've used KVM on Arch for this test.

## Links

* https://github.com/mikejoh/devstack-on-kvm
* https://cluster-api-openstack.sigs.k8s.io/getting-started
* https://image-builder.sigs.k8s.io/capi/providers/openstack.html

## Step-by-step

1. Deploy Devstack
2. Create kind cluster
3. Download `clusterctl`
4. Install CAPO in managment cluster (`kind`)


