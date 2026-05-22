#!/bin/bash
#
# Description: This script is designed to uninstall the 5G testbed at UWaterloo
# deployed using install.sh
# Author: Niloy Saha
# Date: 27/1/2024
# Version: 2.0
# Usage: Please ensure that you run this script as ROOT or with ROOT permissions.
# Notes: This script is designed for use with Ubuntu 22.04.
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

# Based on https://stackoverflow.com/a/53463162/9346339
cecho() {
    RED="\033[0;31m"
    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    CYAN="\033[1;36m"
    NC="\033[0m"
    printf "${!1}${2} ${NC}\n"
}

uninstall_docker() {
  cecho "RED" "Uninstalling Docker ..."
  if [ -x "$(command -v docker)" ]; then
    sudo docker image prune -af || true
    sudo systemctl stop docker || true
    sudo apt-get purge -y docker-engine docker docker.io docker-ce docker-ce-cli containerd containerd.io runc --allow-change-held-packages || true
    cecho "GREEN" "Docker has been removed."
  else
    cecho "YELLOW" "Docker is not installed."
  fi
}

uninstall_containerd() {
  cecho "RED" "Uninstalling containerd ..."
  if [ -x "$(command -v containerd)" ]; then
    sudo systemctl stop containerd || true
    sudo apt-get remove --purge -y containerd.io docker-ce docker-ce-cli || true
    sudo rm -rf /etc/containerd
    cecho "GREEN" "Containerd and related packages have been uninstalled."
  else
    cecho "YELLOW" "Containerd is not installed."
  fi
}

uninstall_k8s() {
  cecho "RED" "Uninstalling Kubernetes components (kubectl, kubeadm, kubelet) ..."
  if [ -x "$(command -v kubectl)" ] || [ -x "$(command -v kubeadm)" ] || [ -x "$(command -v kubelet)" ]; then
    sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
    sudo apt-get remove --purge -y --allow-change-held-packages kubeadm kubectl kubelet kubernetes-cni || true

    # Remove stale apt sources from both old (v1.29) and new (v1.32) installs
    sudo rm -f /etc/apt/sources.list.d/kubernetes.list
    sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    sudo apt-get update

    cecho "GREEN" "Kubernetes components have been removed."
  else
    cecho "YELLOW" "Kubernetes components are not installed."
  fi
}

reset_k8s_cluster() {
  cecho "RED" "Resetting Kubernetes cluster ..."
  if [ -f "/etc/kubernetes/admin.conf" ]; then
    sudo kubeadm reset -f -q
    cecho "GREEN" "Kubernetes cluster has been reset."
  else
    cecho "YELLOW" "No active Kubernetes cluster found."
  fi

  # Clean up all k8s/docker/etcd state directories
  sudo rm -rf /etc/kubernetes
  sudo rm -rf ${HOME}/.kube
  sudo rm -rf /var/lib/kubelet
  sudo rm -rf /var/lib/etcd
  sudo rm -rf /var/lib/etcd2
  sudo rm -rf /var/run/kubernetes
  sudo rm -rf /var/lib/docker
  sudo rm -rf /etc/docker
  sudo rm -rf /var/run/docker.sock
  sudo rm -rf /var/lib/dockershim
  sudo rm -f /etc/apparmor.d/docker
  sudo rm -f /etc/systemd/system/etcd*

  # Remove stale virtual network interfaces left behind by Flannel/CNI
  cecho "RED" "Removing stale network interfaces ..."
  for iface in flannel.1 cni0 docker0; do
    if ip link show "$iface" &>/dev/null; then
      sudo ip link delete "$iface" && cecho "GREEN" "Removed interface $iface" || true
    fi
  done
}

uninstall_cni() {
  cecho "RED" "Uninstalling Flannel CNI ..."
  if kubectl get pods -n kube-flannel -l app=flannel 2>/dev/null | grep -q '1/1'; then
    kubectl delete -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml || true
    cecho "GREEN" "Flannel CNI removed."
  else
    cecho "YELLOW" "Flannel CNI is not running or cluster is already down."
  fi

  cecho "RED" "Removing CNI configuration files ..."
  sudo rm -rf /etc/cni
  sudo rm -rf /opt/cni
}

# FIX: Helm was installed via get-helm-3 script (not apt), so removal is via rm not apt-get
uninstall_helm() {
  cecho "RED" "Removing Helm 3 ..."
  if [ -x "$(command -v helm)" ]; then
    sudo rm -f /usr/local/bin/helm
    # Also clean up stale baltocdn apt source if it exists from old installs
    sudo rm -f /etc/apt/sources.list.d/helm-stable-debian.list
    sudo rm -f /usr/share/keyrings/helm.gpg
    sudo apt-get update
    cecho "GREEN" "Helm 3 has been removed."
  else
    cecho "YELLOW" "Helm 3 is not installed."
  fi
}

uninstall_openebs() {
  cecho "RED" "Removing OpenEBS ..."
  if kubectl get namespace 2>/dev/null | grep -q openebs; then
    helm uninstall openebs --namespace openebs || true
    kubectl delete ns openebs || true
    cecho "GREEN" "OpenEBS has been uninstalled."
  else
    cecho "YELLOW" "OpenEBS is not installed."
  fi
}

# FIX: Bumped operator version from v0.89.1 to v0.94.0 to match install.sh
# FIX: Added OVS bridge deletion before removing the package
remove_ovs_cni() {
  cecho "RED" "Removing OVS CNI setup ..."

  if kubectl get namespace 2>/dev/null | grep -q cluster-network-addons; then
    cecho "RED" "Removing cluster-network-addons operator ..."
    kubectl delete -f https://github.com/kubevirt/cluster-network-addons-operator/releases/download/v0.94.0/operator.yaml || true
    kubectl delete -f https://github.com/kubevirt/cluster-network-addons-operator/releases/download/v0.94.0/network-addons-config.crd.yaml || true
    kubectl delete -f https://github.com/kubevirt/cluster-network-addons-operator/releases/download/v0.94.0/namespace.yaml || true
    cecho "GREEN" "OVS CNI operator has been removed."
  else
    cecho "YELLOW" "OVS CNI operator is not installed."
  fi

  if [ -x "$(command -v ovs-vsctl)" ]; then
    cecho "RED" "Removing OVS bridges ..."
    sudo ovs-vsctl --if-exists del-br n2br
    sudo ovs-vsctl --if-exists del-br n3br
    sudo ovs-vsctl --if-exists del-br n4br

    cecho "RED" "Removing OpenVSwitch ..."
    sudo apt-get remove --purge -y openvswitch-switch
    cecho "GREEN" "OpenVSwitch has been removed."
  else
    cecho "YELLOW" "OpenVSwitch is not installed."
  fi
}

uninstall_multus() {
  cecho "RED" "Uninstalling Multus ..."
  if kubectl get pods -n kube-system -l app=multus 2>/dev/null | grep -q '1/1'; then
    if [ -f "build/multus-cni/deployments/multus-daemonset-thick.yml" ]; then
      kubectl delete -f build/multus-cni/deployments/multus-daemonset-thick.yml || true
      cecho "GREEN" "Multus has been uninstalled."
    else
      cecho "YELLOW" "Multus daemonset manifest not found in build/multus-cni, skipping kubectl delete."
    fi
  else
    cecho "YELLOW" "Multus is not running or cluster is already down."
  fi
}

cleanup() {
  cecho "RED" "Cleaning up build directories and redundant packages ..."
  sudo rm -rf build
  sudo apt-get -y autoremove
  # Clear shell command cache so removed binaries are no longer found
  hash -r
  cecho "GREEN" "Cleanup complete."
}

run-as-root
remove_ovs_cni
uninstall_openebs
uninstall_helm
uninstall_multus
uninstall_cni
reset_k8s_cluster
uninstall_k8s
uninstall_containerd
uninstall_docker
cleanup

cecho "GREEN" "Uninstallation completed successfully."