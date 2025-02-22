# CAPI + CAPO + Devstack

Try out your favourite tools locally! :rocket:

This repository shows you step-by-step on how to run a complete environment locally to test Cluster API, Cluster API Provider OpenStack (on `kind`) and a minimal Devstack (local OpenStack).

I've performed these steps in KVM on Arch.

## Step-by-step

1. Deploy Devstack locally, see this [repository](https://github.com/mikejoh/devstack-on-kvm) on how to this on top of KVM.
2. Download the OpenStack RC file from Horizon, browse to Devstack IP and login, click in the top righ corner on the `admin` name and then choose `OpenStack RC File`. Source this file and enable your `pip` or `pipenv` where the OpenStack client is installed! Also download the `clouds.yaml` for later use with CAPI + CAPO!
2. Create a `kind` cluster:
```
kind create cluster
```
3. Download `clusterctl`, change the destination directory if needed:
```
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.9.4/clusterctl-linux-amd64 -o ~/.local/bin/clusterctl
```
4. Install CAPO in managment cluster (`kind`):
```
kubectl apply -f https://github.com/k-orc/openstack-resource-controller/releases/latest/download/install.yaml
clusterctl init --infrastructure openstack
```
5. Build an image using [`image-builder`](https://image-builder.sigs.k8s.io/capi/providers/openstack.html) with either the qemu builder or (untested at the moment) the [OpenStack builder](https://image-builder.sigs.k8s.io/capi/providers/openstack-remote). I built an image like this:
```
git clone https://github.com/kubernetes-sigs/image-builder.git
image-builder/images/capi/
make build-qemu-ubuntu-2204
```
6. Upload the built image to OpenStack if you built it using anything else than the OpenStack builder:
```
openstack image create "ubuntu-2204-kube-v1.31.4" \
--progress \
--disk-format qcow2 \
--property os_type=linux \
--property os_distro=ubuntu2204 \
--file output/ubuntu-2204-kube-v1.31.4/ubuntu-2204-kube-v1.31.4
```
7. Generate cluster:
```
wget https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-openstack/master/templates/env.rc -O /tmp/env.rc
source /tmp/env.rc ~/Downloads/clouds.yaml openstack
```
Export more enviroment variables that we'll need to define the workload cluster:
```
export KUBERNETES_VERSION=v1.31.4
export OPENSTACK_DNS_NAMESERVERS=1.1.1.1
export OPENSTACK_FAILURE_DOMAIN=nova
export OPENSTACK_CONTROL_PLANE_MACHINE_FLAVOR=m1.small
export OPENSTACK_NODE_MACHINE_FLAVOR=m1.small
export OPENSTACK_IMAGE_NAME=ubuntu-2204-kube-v1.31.4
export OPENSTACK_SSH_KEY_NAME=k8s-devstack01
export OPENSTACK_EXTERNAL_NETWORK_ID=395cd45b-81b5-4a27-a837-f1b916095d84
export CLUSTER_NAME=k8s-devstack01
export CONTROL_PLANE_MACHINE_COUNT=1
export WORKER_MACHINE_COUNT=0
```
