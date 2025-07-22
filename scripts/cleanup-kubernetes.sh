#!/bin/bash
# Complete Kubernetes Cleanup Script for Arch Linux
# This script removes ALL traces of Kubernetes from your system
# Run with: sudo ./cleanup-kubernetes.sh

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_error() {
    echo -e "${RED}[!]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[*]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
fi

print_warning "This script will completely remove Kubernetes from your system!"
print_warning "This includes all data, configurations, and installed packages."
read -p "Are you sure you want to continue? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
    print_status "Cleanup cancelled."
    exit 0
fi

print_status "Starting Kubernetes cleanup..."

# Step 1: Stop all Kubernetes-related services
print_status "Stopping Kubernetes services..."

# Common service names across different Kubernetes distributions
SERVICES=(
    "k3s"
    "k3s-server"
    "k3s-agent"
    "kubelet"
    "kube-proxy"
    "kube-apiserver"
    "kube-controller-manager"
    "kube-scheduler"
    "crio"
)

for service in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        print_status "Stopping $service..."
        systemctl stop "$service" || true
        systemctl disable "$service" || true
    fi
done

# Step 2: Kill any remaining Kubernetes processes
print_status "Killing remaining Kubernetes processes..."

# Process names to kill
PROCESSES=(
    "k3s"
    "k3s-server"
    "kubectl"
    "kubelet"
    "kube-proxy"
    "kube-apiserver"
    "kube-controller"
    "kube-scheduler"
    "flannel"
    "coredns"
)

for process in "${PROCESSES[@]}"; do
    if pgrep -x "$process" > /dev/null; then
        print_status "Killing $process processes..."
        pkill -9 -x "$process" || true
    fi
done

# Step 3: Unmount Kubernetes-related mount points
print_status "Unmounting Kubernetes filesystems..."

# Find and unmount all k3s/kubernetes related mounts
mount | grep -E "(k3s|kubelet|pods)" | awk '{print $3}' | while read -r mount_point; do
    if [[ -n "$mount_point" ]]; then
        print_status "Unmounting $mount_point"
        umount -f "$mount_point" 2>/dev/null || true
    fi
done

# Specifically handle common mount patterns
for pattern in "/var/lib/kubelet/pods" "/var/lib/rancher/k3s" "/run/k3s"; do
    find "$pattern" -type d -name "volume*" -exec umount -f {} \; 2>/dev/null || true
    find "$pattern" -type d -name "secrets" -exec umount -f {} \; 2>/dev/null || true
done

# Step 4: Remove network interfaces
print_status "Removing Kubernetes network interfaces..."

# Remove CNI interfaces
for interface in $(ip link show | grep -E "(cni0|flannel|cali|tunl0|weave|kube-bridge)" | awk -F: '{print $2}' | tr -d ' '); do
    if [[ -n "$interface" ]]; then
        print_status "Removing interface $interface"
        ip link set "$interface" down 2>/dev/null || true
        ip link delete "$interface" 2>/dev/null || true
    fi
done

# Step 5: Clean iptables rules
print_status "Cleaning iptables rules..."

# Save current rules for potential restoration
iptables-save > /tmp/iptables-backup-$(date +%Y%m%d-%H%M%S).txt
print_warning "Current iptables rules backed up to /tmp/"

# Remove Kubernetes-related chains
for table in nat filter mangle; do
    # List all chains in the table
    iptables -t "$table" -L -n | grep -E "(KUBE-|CNI-|K3S)" | awk '{print $2}' | sort -u | while read -r chain; do
        if [[ -n "$chain" ]]; then
            print_status "Flushing chain $chain in table $table"
            iptables -t "$table" -F "$chain" 2>/dev/null || true
        fi
    done
    
    # Delete the chains after flushing
    iptables -t "$table" -L -n | grep -E "(KUBE-|CNI-|K3S)" | awk '{print $2}' | sort -u | while read -r chain; do
        if [[ -n "$chain" ]]; then
            print_status "Deleting chain $chain in table $table"
            iptables -t "$table" -X "$chain" 2>/dev/null || true
        fi
    done
done

# Remove specific rules that reference Kubernetes
iptables-save | grep -v KUBE- | grep -v CNI- | grep -v K3S | iptables-restore || true

# Step 6: Remove installed packages
print_status "Removing Kubernetes-related packages..."

# First, remove AUR packages (these won't be removed by pacman)
AUR_PACKAGES=(
    "kubernetes"
    "kubernetes-bin" 
    "kubectl"
    "kubectl-bin"
    "kubelet"
    "kubeadm"
    "k3s-bin"
    "k9s"
    "helm"
    "helm-bin"
    "k0s-bin"
    "minikube"
    "minikube-bin"
    "kind"
    "kind-bin"
    "rancher"
    "cri-o"
    "cri-o-bin"
)

print_status "Checking for AUR packages..."
for package in "${AUR_PACKAGES[@]}"; do
    if pacman -Qi "$package" &>/dev/null; then
        print_status "Removing AUR package: $package"
        pacman -Rns --noconfirm "$package" || true
    fi
done

# Step 7: Remove Kubernetes directories
print_status "Removing Kubernetes directories..."

# Directories to remove completely
REMOVE_DIRS=(
    "/etc/kubernetes"
    "/etc/k3s"
    "/etc/rancher"
    "/etc/cni"
    "/etc/crio"
    "/var/lib/kubelet"
    "/var/lib/k3s"
    "/var/lib/rancher"
    "/var/lib/etcd"
    "/var/lib/cni"
    "/var/lib/calico"
    "/var/lib/weave"
    "/var/log/k3s"
    "/var/log/kubernetes"
    "/var/log/pods"
    "/opt/cni"
    "/run/k3s"
    "/run/kubernetes"
    "/run/flannel"
    "/run/calico"
    "/usr/local/bin/k3s*"
    "/usr/local/bin/kubectl*"
    "/usr/local/bin/crictl*"
    "/usr/local/bin/ctr*"
    "/usr/local/bin/helm*"
)

for dir in "${REMOVE_DIRS[@]}"; do
    if [[ -e "$dir" ]]; then
        print_status "Removing $dir"
        rm -rf "$dir"
    fi
done

# Remove specific files
FILES_TO_REMOVE=(
    "/usr/local/bin/k3s"
    "/usr/local/bin/k3s-killall.sh"
    "/usr/local/bin/k3s-uninstall.sh"
    "/usr/local/bin/kubectl"
    "/usr/local/bin/crictl"
    "/usr/local/bin/ctr"
    "/usr/local/bin/helm"
    "/usr/local/bin/kubelet"
    "/usr/local/bin/kubeadm"
    "/usr/local/bin/kubens"
    "/usr/local/bin/kubectx"
    "/usr/local/bin/k9s"
)

for file in "${FILES_TO_REMOVE[@]}"; do
    if [[ -f "$file" ]]; then
        print_status "Removing $file"
        rm -f "$file"
    fi
done

# Step 8: Clean systemd units
print_status "Removing systemd unit files..."

SYSTEMD_UNITS=(
    "/etc/systemd/system/k3s.service"
    "/etc/systemd/system/k3s-agent.service"
    "/etc/systemd/system/kubelet.service"
    "/usr/lib/systemd/system/k3s.service"
    "/usr/lib/systemd/system/k3s-agent.service"
)

for unit in "${SYSTEMD_UNITS[@]}"; do
    if [[ -f "$unit" ]]; then
        print_status "Removing systemd unit: $unit"
        rm -f "$unit"
    fi
done

# Reload systemd
systemctl daemon-reload

# Step 9: Clean user configurations
print_status "Cleaning user configurations..."

# Get all users with home directories
for user_home in /home/*; do
    if [[ -d "$user_home" ]]; then
        username=$(basename "$user_home")
        
        # Remove .kube directory
        if [[ -d "$user_home/.kube" ]]; then
            print_status "Removing .kube directory for user $username"
            rm -rf "$user_home/.kube"
        fi
        
        # Remove helm directories
        if [[ -d "$user_home/.helm" ]]; then
            print_status "Removing .helm directory for user $username"
            rm -rf "$user_home/.helm"
        fi
        
        # Remove k9s config
        if [[ -d "$user_home/.k9s" ]]; then
            print_status "Removing .k9s directory for user $username"
            rm -rf "$user_home/.k9s"
        fi
    fi
done

# Also clean root's directories
for dir in "/root/.kube" "/root/.helm" "/root/.k9s"; do
    if [[ -d "$dir" ]]; then
        print_status "Removing $dir"
        rm -rf "$dir"
    fi
done

# Step 11: Clean cgroups
print_status "Cleaning cgroups..."
if [[ -d "/sys/fs/cgroup/systemd/kubepods" ]]; then
    find /sys/fs/cgroup/systemd/kubepods -type d -exec rmdir {} \; 2>/dev/null || true
fi

# Step 12: Final cleanup
print_status "Performing final cleanup..."

# Remove any leftover tmp files
rm -rf /tmp/k3s*
rm -rf /tmp/k8s*

# Clear package cache for removed packages
pacman -Scc --noconfirm

print_status "Kubernetes cleanup complete!"
print_warning "Please reboot your system to ensure all changes take effect."
print_warning "After reboot, you can start fresh with your new Kubernetes installation."

# Optional: Show what might still be left
print_status "Checking for any remaining Kubernetes-related files..."
remaining=$(find /etc /var /opt /usr/local/bin -name "*kube*" -o -name "*k3s*" -o -name "*k8s*" 2>/dev/null | head -20)
if [[ -n "$remaining" ]]; then
    print_warning "Some files may still remain:"
    echo "$remaining"
    print_warning "You may want to review these manually."
fi