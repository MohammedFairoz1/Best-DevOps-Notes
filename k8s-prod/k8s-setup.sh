#!/bin/bash

set -e  # Exit on any error

echo "=== Kubernetes Setup Script ==="

# Function to print section headers
print_section() {
    echo ""
    echo "=== $1 ==="
    echo ""
}

# Function to check command success
check_success() {
    if [ $? -eq 0 ]; then
        echo "✓ $1"
    else
        echo "✗ $1 failed!"
        exit 1
    fi
}

print_section "Disabling swap"
swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
check_success "Swap disabled"

print_section "Configuring kernel modules and sysctl"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
check_success "Kernel modules and sysctl configured"

print_section "Verifying kernel configuration"
echo "Loaded modules:"
lsmod | grep br_netfilter || echo "br_netfilter not loaded"
lsmod | grep overlay || echo "overlay not loaded"

echo "Sysctl values:"
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
check_success "Kernel configuration verified"

print_section "Installing container runtime (containerd)"
# Download and install containerd
if [ ! -f containerd-1.7.14-linux-amd64.tar.gz ]; then
    curl -LO https://github.com/containerd/containerd/releases/download/v1.7.14/containerd-1.7.14-linux-amd64.tar.gz
    check_success "Containerd downloaded"
fi

sudo tar Cxzvf /usr/local containerd-1.7.14-linux-amd64.tar.gz
check_success "Containerd extracted"

# Download containerd service file
if [ ! -f containerd.service ]; then
    curl -LO https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
    check_success "Containerd service file downloaded"
fi

sudo mkdir -p /usr/local/lib/systemd/system/
sudo mv containerd.service /usr/local/lib/systemd/system/
sudo mkdir -p /etc/containerd

# Generate default config and enable SystemdCgroup
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

sudo systemctl daemon-reload
sudo systemctl enable --now containerd
check_success "Containerd service configured"

# Wait a moment for containerd to start
sleep 5

echo "Containerd status:"
systemctl status containerd --no-pager -l

print_section "Installing runc"
if [ ! -f runc.amd64 ]; then
    curl -LO https://github.com/opencontainers/runc/releases/download/v1.1.12/runc.amd64
    check_success "Runc downloaded"
fi

sudo install -m 755 runc.amd64 /usr/local/sbin/runc
check_success "Runc installed"

print_section "Installing CNI plugins"
if [ ! -f cni-plugins-linux-amd64-v1.5.0.tgz ]; then
    curl -LO https://github.com/containernetworking/plugins/releases/download/v1.5.0/cni-plugins-linux-amd64-v1.5.0.tgz
    check_success "CNI plugins downloaded"
fi

sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.5.0.tgz
check_success "CNI plugins installed"

print_section "Installing kubeadm, kubelet and kubectl"
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Add Kubernetes repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet=1.29.6-1.1 kubeadm=1.29.6-1.1 kubectl=1.29.6-1.1 --allow-downgrades --allow-change-held-packages
sudo apt-mark hold kubelet kubeadm kubectl
check_success "Kubernetes tools installed"

print_section "Verifying installations"
echo "kubeadm version:"
kubeadm version

echo "kubelet version:"
kubelet --version

echo "kubectl client version:"
kubectl version --client

print_section "Configuring crictl for containerd"
sudo crictl config runtime-endpoint unix:///var/run/containerd/containerd.sock
check_success "crictl configured"

print_section "Setup completed successfully!"
echo ""
echo "Summary of what was installed:"
echo "✓ Swap disabled"
echo "✓ Kernel modules loaded (overlay, br_netfilter)"
echo "✓ Sysctl parameters configured"
echo "✓ Containerd 1.7.14 installed and running"
echo "✓ Runc 1.1.12 installed"
echo "✓ CNI plugins 1.5.0 installed"
echo "✓ Kubernetes tools installed:"
echo "  - kubeadm 1.29.6"
echo "  - kubelet 1.29.6" 
echo "  - kubectl 1.29.6"
echo "✓ crictl configured for containerd"
echo ""
echo "Next steps:"
echo "1. Initialize the cluster with: sudo kubeadm init"
echo "2. Set up kubeconfig for your user"
echo "3. Install a CNI plugin (like Calico or Flannel)"