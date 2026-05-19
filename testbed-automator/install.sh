#!/bin/bash
#
# Description: This script is designed to deploy the 5G testbed at UWaterloo.
# Author: Niloy Saha
# Date: 24/10/2023
# Version: 2.0
# Usage: Please ensure that you run this script as ROOT or with ROOT permissions.
# Notes: This script is designed for use with Ubuntu 22.04.
# Changelog (v2.0):
#   - Fixed: Replaced defunct baltocdn.com Helm repo with official get-helm-3 installer
#   - Fixed: Kubernetes bumped from EOL v1.29 -> v1.32
#   - Fixed: ovs-cni cluster-network-addons-operator bumped from v0.89.1 -> v0.94.0
#   - Fixed: install-containerd now reconfigures containerd even if already installed
#   - Fixed: install-packages uses pip3 install with --break-system-packages for Ubuntu 22.04+
#   - Fixed: apt-get install lines now use -y flag consistently (helm was missing it)
#   - Fixed: setup-ovs-cni apt-get install missing -y flag
#   - Improved: run-as-root now exits with code 1
#   - Improved: Added set -euo pipefail for safer script execution
# ==============================================================================

set -euo pipefail

run-as-root() {
  if [ "$EUID" -ne 0 ]; then
    cecho "RED" "This script must be run as ROOT"
    exit 1
  fi
}

timer-sec() {
  secs=$((${1}))
  while [ $secs -gt 0 ]; do
    echo -ne "Waiting for $secs\033[0K seconds ...\r"
    sleep 1
    : $((secs--))
  done
}

install-packages() {
  sudo apt-get update
  sudo apt-get install -y vim tmux git curl iproute2 iputils-ping iperf3 tcpdump python3-pip
  # --break-system-packages required on Ubuntu 22.04+ with PEP 668 enforcement
  sudo pip3 install virtualenv --break-system-packages
}

# Based on https://stackoverflow.com/a/53463162/9346339
cecho() {
    RED="\033[0;31m"
    GREEN="\033[0;32m"  # <-- [0 means not bold
    YELLOW="\033[1;33m" # <-- [1 means bold
    CYAN="\033[1;36m"
    NC="\033[0m" # No Color
    printf "${!1}${2} ${NC}\n"
}

# Disable Swap
disable-swap() {
    cecho "GREEN" "Disabling swap ..."
    if [ -n "$(swapon -s)" ]; then
        sudo swapoff -a
        # Comment out the swap entry in /etc/fstab to disable it permanently
        sudo sed -i '/swap/ s/^/#/' /etc/fstab
        echo "Swap has been disabled and commented out in /etc/fstab."
    else
        echo "Swap is not enabled on this system."
    fi
}

disable-firewall() {
  cecho "YELLOW" "Disabling firewall ..."
  sudo ufw disable
}

# Install containerd as Kubernetes CRI
# Based on https://docs.docker.com/engine/install/ubuntu/
install-containerd() {
  if [ -x "$(command -v containerd)" ]; then
    cecho "YELLOW" "Containerd is already installed. Checking configuration ..."
  else
    cecho "GREEN" "Installing containerd ..."
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  # Always ensure containerd config is correct (handles both fresh installs and pre-existing)
  sudo mkdir -p /etc/containerd
  sudo bash -c 'containerd config default > /etc/containerd/config.toml'
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl enable containerd
  sudo systemctl restart containerd

  # Check if Containerd is running
  if sudo systemctl is-active containerd &> /dev/null; then
    cecho "GREEN" "Containerd is running :)"
  else
    cecho "RED" "Containerd installation failed or is not running!"
    exit 1
  fi
}

# Setup K8s Networking
# Based on https://kubernetes.io/docs/setup/production-environment/container-runtimes/#forwarding-ipv4-and-letting-iptables-see-bridged-traffic
setup-k8s-networking() {
  cecho "GREEN" "Setting up Kubernetes networking ..."

  cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

  sudo modprobe overlay
  sudo modprobe br_netfilter

  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

  sudo sysctl --system > /dev/null
}

# Install Kubernetes
# FIX: Bumped from EOL v1.29 to v1.32
install-k8s() {
  if [ -x "$(command -v kubectl)" ] && [ -x "$(command -v kubeadm)" ] && [ -x "$(command -v kubelet)" ]; then
    cecho "YELLOW" "Kubernetes components (kubectl, kubeadm, kubelet) are already installed."
  else
    cecho "GREEN" "Installing Kubernetes components (kubectl, kubeadm, kubelet) ..."
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gpg

    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
  fi
}

create-k8s-cluster() {
  if [ -f "/etc/kubernetes/admin.conf" ]; then
    cecho "YELLOW" "A Kubernetes cluster already exists. Skipping cluster creation."
  else
    cecho "GREEN" "Creating k8s cluster ..."
    sudo kubeadm init --config kubeadm-config.yaml

    mkdir -p ${HOME}/.kube
    sudo cp -i /etc/kubernetes/admin.conf ${HOME}/.kube/config
    sudo chown $(id -u):$(id -g) ${HOME}/.kube/config

    timer=60
    cecho "YELLOW" "Waiting $timer secs for cluster to be ready"
    timer-sec $timer

    cecho "GREEN" "Allowing scheduling pods on master node ..."
    kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
  fi
}

# Install Flannel as CNI
install-cni() {
  if kubectl get pods -n kube-flannel -l app=flannel 2>/dev/null | grep -q '1/1'; then
    cecho "YELLOW" "Flannel is already running. Skipping installation."
  else
    cecho "GREEN" "Installing Flannel as primary CNI ..."
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    timer-sec 60
    kubectl wait pods -n kube-flannel -l app=flannel --for condition=Ready --timeout=120s
  fi
}

# Install Multus as meta CNI
install-multus() {
  if kubectl get pods -n kube-system -l app=multus 2>/dev/null | grep -q '1/1'; then
    cecho "YELLOW" "Multus is already running. Skipping installation."
  else
    cecho "GREEN" "Installing Multus as meta CNI ..."
    git -C build/multus-cni pull 2>/dev/null || git clone https://github.com/k8snetworkplumbingwg/multus-cni.git build/multus-cni
    cd build/multus-cni
    cat ./deployments/multus-daemonset-thick.yml | kubectl apply -f -
    cd -
    timer-sec 30
    kubectl wait pods -n kube-system -l app=multus --for condition=Ready --timeout=120s
  fi
}

# Install Helm 3
# FIX: Replaced defunct baltocdn.com repo with official get-helm-3 installer script
install-helm() {
  HELM_VERSION=$(helm version --short 2> /dev/null || true)

  if [[ "$HELM_VERSION" != *"v3"* ]]; then
    cecho "GREEN" "Helm 3 is not installed. Proceeding to install Helm ..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    cecho "YELLOW" "Helm 3 is already installed."
  fi
}

install-openebs() {
  if kubectl get pods -n openebs -l app=openebs 2>/dev/null | grep -q '1/1'; then
    cecho "YELLOW" "OpenEBS is already running. Skipping installation."
  else
    cecho "GREEN" "Installing OpenEBS for storage management ..."
    helm repo add openebs https://openebs.github.io/charts
    helm repo update
    helm upgrade --install openebs --namespace openebs openebs/openebs --create-namespace

    kubectl patch storageclass openebs-hostpath -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  fi
}

# FIX: cluster-network-addons-operator bumped from v0.89.1 to v0.94.0
# FIX: Added -y flag to apt-get install openvswitch-switch
setup-ovs-cni() {
  if [ -x "$(command -v ovs-vsctl)" ]; then
    cecho "YELLOW" "OpenVSwitch is already installed."
  else
    cecho "GREEN" "Installing OpenVSwitch ..."
    sudo apt-get update
    sudo apt-get install -y openvswitch-switch
  fi

  cecho "GREEN" "Configuring bridges for use by ovs-cni ..."
  sudo ovs-vsctl --may-exist add-br n2br
  sudo ovs-vsctl --may-exist add-br n3br
  sudo ovs-vsctl --may-exist add-br n4br

  cecho "GREEN" "Installing ovs-cni ..."
  kubectl apply -f https://github.com/kubevirt/cluster-network-addons-operator/releases/download/v0.94.0/namespace.yaml
  kubectl apply -f https://github.com/kubevirt/cluster-network-addons-operator/releases/download/v0.94.0/network-addons-config.crd.yaml
  kubectl apply -f https://github.com/kubevirt/cluster-network-addons-operator/releases/download/v0.94.0/operator.yaml

  kubectl apply -f https://gist.githubusercontent.com/niloysh/1f14c473ebc08a18c4b520a868042026/raw/d96f07e241bb18d2f3863423a375510a395be253/network-addons-config.yaml

  timer-sec 30
  kubectl wait networkaddonsconfig cluster --for condition=Available
}

run-as-root
install-packages
disable-swap
disable-firewall
setup-k8s-networking
install-containerd
install-k8s
create-k8s-cluster
install-cni
install-multus
install-helm
install-openebs
setup-ovs-cni