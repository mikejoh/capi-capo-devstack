# CAPI, CAPO and DevStack!

Try out your favourite tools and tech stack locally! :rocket:

This repository shows you step-by-step on how to run a complete environment locally to test:
* [Cluster API](https://github.com/kubernetes-sigs/cluster-api)
* [Cluster API Provider OpenStack](https://github.com/kubernetes-sigs/cluster-api-provider-openstack)
* [Minikube](https://minikube.sigs.k8s.io/docs/start/?arch=%2Flinux%2Fx86-64%2Fstable%2Fbinary+download)
* [DevStack](https://github.com/openstack/devstack)

## Overview

This drawing shows a brief overview on what we're trying to achieve:

<div align="center">
  <img src="https://github.com/user-attachments/assets/f6eed09d-52fd-4e4a-83da-0d2909bff894" alt="">
</div>

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
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.9.5/clusterctl-linux-amd64 -o ~/.local/bin/clusterctl
```

5. Install CAPO in the managment cluster (`minikube`):

```bash
export CLUSTER_TOPOLOGY=true
kubectl apply -f https://github.com/k-orc/openstack-resource-controller/releases/latest/download/install.yaml
clusterctl init --infrastructure openstack
```

Notes:
* `clusterctl init` is dependant on configuration, either via environment variables or a [configuration file](https://cluster-api.sigs.k8s.io/clusterctl/configuration).
* `cert-manager` is installed during `init`, this might not be wanted if you already have one running.
* The default bootstrap providers are `kubeadm`, you can select others.

6. Build an image using [`image-builder`](https://image-builder.sigs.k8s.io/capi/providers/openstack.html), used the `qemu` builder:

```bash
git clone https://github.com/kubernetes-sigs/image-builder.git
cd image-builder/images/capi/
make build-qemu-ubuntu-2404
```

7. Upload the built image to OpenStack if you built it using anything else than the OpenStack builder:

```bash
openstack image create "ubuntu-2204-kube-v1.31.6" \
  --progress \
  --disk-format qcow2 \
  --property os_type=linux \
  --property os_distro=ubuntu2204 \
  --file output/ubuntu-2204-kube-v1.31.6/ubuntu-2204-kube-v1.31.6
```

8. Create a SSH keypair:

```bash
openstack keypair create --type ssh k8s-devstack01
```

Take a note of that the private SSH key and store it somewhere safe.

9. Install needed CAPO prerequisites and generate cluster manifests:

Make sure you've prepared your `clouds.yaml` accordingly, here's an example:

```bash
clouds:
  openstack:
    auth:
      auth_url: http://<DevStack IP>:5000//v3
      username: "demo"
      password: "secret"
      project_name: "admin"
      project_id: "<ID>"
      user_domain_name: "Default"
    region_name: "RegionOne"
    interface: "public"
    identity_api_version: 3
```

```bash
wget https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-openstack/master/templates/env.rc -O /tmp/env.rc
source /tmp/env.rc clouds.yaml openstack
```

Export more environment variables that we'll need to define the workload cluster:

```bash
export KUBERNETES_VERSION=v1.31.6
export OPENSTACK_DNS_NAMESERVERS=1.1.1.1
export OPENSTACK_FAILURE_DOMAIN=nova
export OPENSTACK_CONTROL_PLANE_MACHINE_FLAVOR=m1.medium
export OPENSTACK_NODE_MACHINE_FLAVOR=m1.medium
export OPENSTACK_IMAGE_NAME=ubuntu-2204-kube-v1.31.6
export OPENSTACK_SSH_KEY_NAME=k8s-devstack01
export OPENSTACK_EXTERNAL_NETWORK_ID=<ID>
export CLUSTER_NAME=k8s-devstack01
export CONTROL_PLANE_MACHINE_COUNT=1
export WORKER_MACHINE_COUNT=0
```

_Please note that you'll need to fetch the `public` network ID and add it to the `OPENSTACK_EXTERNAL_NETWORK_ID` environment variable. Also the flavor needs to have at least 2 cores otherwise `kubeadm` will fail, this can be ignored from a `kubeadm` perspective but that's not covered here._

10. Generate the cluster manifests and apply them in the `minikube` cluster:

```bash
clusterctl generate cluster k8s-devstack01 --infrastructure openstack > k8s-devstack01.yaml
kubectl apply -f k8s-devstack01.yaml
```

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
export KUBECONFIG=k8s-devstack01.kubeconfig
```

You should now be able to reach the cluster running within the DevStack environment! 🎉

13. Install a CNI (Cilium), manually for now:

```bash
helm repo add cilium https://helm.cilium.io/
```

```bash
helm upgrade --install cilium cilium/cilium --version 1.17.1 \
  --namespace kube-system \
  --set hubble.enabled=false \
  --set envoy.enabled=false \
  --set operator.replicas=1
```

14. Install the OpenStack Cloud Provider:

```bash
git clone --depth=1 https://github.com/kubernetes-sigs/cluster-api-provider-openstack.git
```

Generate the external cloud provider configuration with the provided helper script:

```bash
./templates/create_cloud_conf.sh ~/Downloads/clouds.yaml openstack > /tmp/cloud.conf
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
  --values occm-values.yaml
```

If everything went as expected pending Pods should've been scheduled and all Pods shall have IP addresses assigned to them.

15. Done! 🚀
