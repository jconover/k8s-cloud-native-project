#!/bin/bash

# Kubernetes Cluster Setup Script
# For 3-node cluster: k8s-master-01, k8s-worker-01, k8s-worker-02
# Ubuntu 24.04 with kubeadm

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Cluster configuration
MASTER_IP="192.168.68.86"
WORKER1_IP="192.168.68.88"
WORKER2_IP="192.168.68.83"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
K8S_VERSION="1.34.1"

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root. Run as a regular user with sudo privileges."
    fi
    
    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        error "This script requires sudo privileges. Please run: sudo visudo and add your user to sudoers."
    fi
    
    # Check network connectivity
    for ip in $MASTER_IP $WORKER1_IP $WORKER2_IP; do
        if ! ping -c 1 -W 5 $ip &> /dev/null; then
            error "Cannot reach $ip. Please check network connectivity."
        fi
    done
    
    log "Prerequisites check passed!"
}

setup_hosts_file() {
    log "Setting up /etc/hosts file..."
    
    # Backup original hosts file
    sudo cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d_%H%M%S)
    
    # Add cluster nodes to hosts file
    cat << EOF | sudo tee -a /etc/hosts

# Kubernetes Cluster Nodes
$MASTER_IP k8s-master-01
$WORKER1_IP k8s-worker-01
$WORKER2_IP k8s-worker-02
EOF
    
    log "Hosts file updated successfully!"
}

install_container_runtime() {
    log "Installing containerd container runtime..."
    
    # Install dependencies
    sudo apt-get update
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Set up Docker repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install containerd
    sudo apt-get update
    sudo apt-get install -y containerd.io
    
    # Configure containerd
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml
    
    # Enable systemd cgroup driver
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # Restart and enable containerd
    sudo systemctl restart containerd
    sudo systemctl enable containerd
    
    log "Containerd installed and configured successfully!"
}

configure_system() {
    log "Configuring system for Kubernetes..."
    
    # Disable swap
    sudo swapoff -a
    sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    
    # Load kernel modules
    cat << EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    
    sudo modprobe overlay
    sudo modprobe br_netfilter
    
    # Set sysctl params
    cat << EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    
    sudo sysctl --system
    
    log "System configuration completed!"
}

install_kubernetes_tools() {
    log "Installing Kubernetes tools (kubeadm, kubelet, kubectl)..."
    
    # Add Kubernetes APT repository
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
    
    # Install Kubernetes tools
    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    
    # Hold packages to prevent automatic updates
    sudo apt-mark hold kubelet kubeadm kubectl
    
    log "Kubernetes tools installed successfully!"
}

initialize_master_node() {
    log "Initializing Kubernetes master node..."
    
    # Initialize cluster
    sudo kubeadm init \
        --apiserver-advertise-address=$MASTER_IP \
        --pod-network-cidr=$POD_CIDR \
        --service-cidr=$SERVICE_CIDR \
        --kubernetes-version=v$K8S_VERSION \
        --node-name=k8s-master-01
    
    # Set up kubectl for regular user
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    
    # Generate join command for worker nodes
    kubeadm token create --print-join-command > /tmp/kubeadm-join-command.sh
    chmod +x /tmp/kubeadm-join-command.sh
    
    log "Master node initialized successfully!"
    log "Join command saved to /tmp/kubeadm-join-command.sh"
}

install_cni_plugin() {
    log "Installing Flannel CNI plugin..."
    
    # Apply Flannel CNI
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    
    # Wait for flannel pods to be ready
    log "Waiting for Flannel pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=flannel -n kube-flannel --timeout=300s
    
    log "Flannel CNI plugin installed successfully!"
}

setup_worker_nodes() {
    log "Setting up worker nodes..."
    
    if [[ ! -f /tmp/kubeadm-join-command.sh ]]; then
        error "Join command not found. Please run this script on the master node first."
    fi
    
    # Copy join command to worker nodes and execute
    for worker_ip in $WORKER1_IP $WORKER2_IP; do
        log "Setting up worker node: $worker_ip"
        
        # Copy join command to worker
        scp /tmp/kubeadm-join-command.sh ubuntu@$worker_ip:/tmp/
        
        # Execute join command on worker
        ssh ubuntu@$worker_ip "sudo bash /tmp/kubeadm-join-command.sh"
        
        log "Worker node $worker_ip joined successfully!"
    done
}

verify_cluster() {
    log "Verifying cluster setup..."
    
    # Wait for all nodes to be ready
    log "Waiting for all nodes to be ready..."
    kubectl wait --for=condition=ready node --all --timeout=300s
    
    # Display cluster information
    echo -e "\n${BLUE}=== Cluster Information ===${NC}"
    kubectl cluster-info
    
    echo -e "\n${BLUE}=== Node Status ===${NC}"
    kubectl get nodes -o wide
    
    echo -e "\n${BLUE}=== System Pods ===${NC}"
    kubectl get pods -n kube-system
    
    log "Cluster verification completed!"
}

install_helm() {
    log "Installing Helm..."
    
    # Download and install Helm using the official install script
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    rm get_helm.sh
    
    # Verify Helm installation
    helm version
    
    log "Helm installed successfully!"
}

setup_storage_class() {
    log "Setting up local storage class..."
    
    # Create local path provisioner
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml
    
    # Set as default storage class
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
    log "Local storage class configured successfully!"
}

create_namespaces() {
    log "Creating application namespaces..."
    
    # Create namespaces
    kubectl create namespace applications --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace infrastructure --dry-run=client -o yaml | kubectl apply -f -
    
    log "Namespaces created successfully!"
}

main() {
    log "Starting Kubernetes cluster setup..."
    
    # Determine node type
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    
    case $CURRENT_IP in
        $MASTER_IP)
            log "Setting up MASTER node..."
            check_prerequisites
            setup_hosts_file
            configure_system
            install_container_runtime
            install_kubernetes_tools
            initialize_master_node
            install_cni_plugin
            install_helm
            setup_storage_class
            create_namespaces
            
            log "Master node setup completed!"
            log "Now run this script on worker nodes to join them to the cluster."
            ;;
        $WORKER1_IP|$WORKER2_IP)
            log "Setting up WORKER node..."
            check_prerequisites
            setup_hosts_file
            configure_system
            install_container_runtime
            install_kubernetes_tools
            
            log "Worker node setup completed!"
            log "Run the join command provided by the master node."
            ;;
        *)
            error "Unknown node IP: $CURRENT_IP. Please check your network configuration."
            ;;
    esac
    
    log "Cluster setup completed successfully!"
    log "Next steps:"
    log "1. Verify cluster: kubectl get nodes"
    log "2. Deploy infrastructure: ./scripts/deploy-infrastructure.sh"
    log "3. Deploy applications: ./scripts/deploy-applications.sh"
}

# Run main function
main "$@"
