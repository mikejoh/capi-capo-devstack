# CAPI + CAPO + Devstack

Try out your favourite tools locally! :rocket:

This repository shows you step-by-step on how to run a complete environment locally to test [Cluster API](https://github.com/kubernetes-sigs/cluster-api), [Cluster API Provider OpenStack](https://github.com/kubernetes-sigs/cluster-api-provider-openstack) (on `kind`) and a minimal [Devstack](https://github.com/openstack/devstack) (local OpenStack).

I've performed these steps in KVM on Arch.

## Step-by-step

1. Deploy Devstack locally, see this [repository](https://github.com/mikejoh/devstack-on-kvm) on how to do this on top of KVM.

2. Download the OpenStack RC file via Horizon.

3. Create a `kind` cluster:

```
kind create cluster
```

4. Enable connectivity between `kind` Pods and the Devstack VM:

Note which bridge the Devstack VM are attached to:

```
sudo virsh net-info devstack_net
```

Create a new Docker mcvlan network using the same subnet and gateway as configured for the devstack_net in KVM, example:

```
docker network create -d macvlan --subnet=192.168.11.0/24 --gateway=192.168.11.1 -o parent=virbr2 devstack_net
```

Connect the kind container to this network

```
docker network connect devstack_net <container ID>
```

_Please make sure you test the connectivity between a Pod in the `kind` cluster and the Devstack VM IP with e.g. `curl` before proceeding!_

```

```

5. Download `clusterctl`, change the destination directory if needed:

```
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.9.4/clusterctl-linux-amd64 -o ~/.local/bin/clusterctl
```

6. Install CAPO in the managment cluster (`kind`):

```
export CLUSTER_TOPOLOGY=true
kubectl apply -f https://github.com/k-orc/openstack-resource-controller/releases/latest/download/install.yaml
clusterctl init --infrastructure openstack
```

7. Build an image using [`image-builder`](https://image-builder.sigs.k8s.io/capi/providers/openstack.html), i used the `qemu` builder or (untested at the moment) the [OpenStack builder](https://image-builder.sigs.k8s.io/capi/providers/openstack-remote). The `build-qemu-ubuntu-2404` make target was broken when writing this. I built an `22.04` image like this:

```
git clone https://github.com/kubernetes-sigs/image-builder.git
image-builder/images/capi/
make build-qemu-ubuntu-2204
```

8. Upload the built image to OpenStack if you built it using anything else than the OpenStack builder:

```
openstack image create "ubuntu-2204-kube-v1.31.4" \
  --progress \
  --disk-format qcow2 \
  --property os_type=linux \
  --property os_distro=ubuntu2204 \
  --public \
  --file output/ubuntu-2204-kube-v1.31.4/ubuntu-2204-kube-v1.31.4
```

9. Create a SSH keypair:

```
openstack keypair create --type ssh k8s-devstack01
```

Take a note of that the private SSH key and store it somewhere safe.

10. Install needed CAPO prerequisites and generate cluster manifests:

_Make sure you've prepared your `clouds.yaml` accordingly._

```
wget https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-openstack/master/templates/env.rc -O /tmp/env.rc
source /tmp/env.rcclouds.yaml openstack
```

Export more environment variables that we'll need to define the workload cluster:

```
export KUBERNETES_VERSION=v1.31.4
export OPENSTACK_DNS_NAMESERVERS=1.1.1.1
export OPENSTACK_FAILURE_DOMAIN=nova
export OPENSTACK_CONTROL_PLANE_MACHINE_FLAVOR=m1.medium
export OPENSTACK_NODE_MACHINE_FLAVOR=m1.medium
export OPENSTACK_IMAGE_NAME=ubuntu-2204-kube-v1.31.4
export OPENSTACK_SSH_KEY_NAME=k8s-devstack01
export OPENSTACK_EXTERNAL_NETWORK_ID=<ID>
export CLUSTER_NAME=k8s-devstack01
export CONTROL_PLANE_MACHINE_COUNT=1
export WORKER_MACHINE_COUNT=0
```

_Please note that you'll need to fetch the `public` network ID and add it to the `OPENSTACK_EXTERNAL_NETWORK_ID` environment variable. Also the flavor needs to have at least 2 cores otherwise `kubeadm` will fail, this can be ignored from a `kubeadm` perspective but that's not covered here._

10. Generate the cluster manifests and apply them in the `kind` cluster:

```
clusterctl generate cluster k8s-devstack01 --infrastructure openstack > k8s-devstack01.yaml
kubectl apply -f k8s-devstack01.yaml
```

11. Check the cluster status in the `kind` cluster, also check the logs of, primarily, the `capo-controller`:

```
kubectl get clusters
```

12. Download the cluster kubeconfig and test connectivity:

```
clusterctl get kubeconfig k8s-devstack01 > k8s-devstack01.kubeconfig
export KUBECONFIG=k8s-devstack01.kubeconfig
```

You should now be able to reach the cluster running within the DevStack environment! 🎉

13. Install a CNI (Cilium), manually for now:

_Please note that we're replacing `kube-proxy` with Cilium at the same time in the steps below._

```
helm repo add cilium https://helm.cilium.io/
```

```
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy
```

`k8sServiceHost` below should be set to the control-plane VM IP, not the floating IP:

```
helm upgrade --install cilium cilium/cilium --version 1.17.1 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=10.6.0.177 \
  --set k8sServicePort=6443 \
  --set hubble.enabled=false \
  --set envoy.enabled=false \
  --set operator.replicas=1
```

14. Install the OpenStack cloud provider:

```
git clone --depth=1 https://github.com/kubernetes-sigs/cluster-api-provider-openstack.git
```

Generate the external cloud provider configuration with the provided helper script:

```
./templates/create_cloud_conf.sh ~/Downloads/clouds.yaml openstack > /tmp/cloud.conf
```

Create the needed secret:

```
kuebctl create secret -n kube-system generic cloud-config --from-file=/tmp/cloud.conf
```

Create the needed Kubernetes resources for the OpenStack cloud provider:

```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/controller-manager/cloud-controller-manager-roles.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/controller-manager/cloud-controller-manager-role-bindings.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/controller-manager/openstack-cloud-controller-manager-ds.yaml
```

If everything went as expected the `coredns` Pods would be scheduled since they didn't tolerate the special taint added by Kubernetes, this taint is removed when the external cloud provider successfully initializes all nodes.
