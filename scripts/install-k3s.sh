#!/bin/bash
set -euo pipefail

echo "🚀 Starting k3s installation with disabled traefik and servicelb..."

# Function to print colored output
print_message() {
    echo -e "\033[1;34m$1\033[0m"
}

print_error() {
    echo -e "\033[1;31m$1\033[0m"
}

print_success() {
    echo -e "\033[1;32m$1\033[0m"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    print_error "This script should not be run as root!"
    exit 1
fi

# Create the k3s config directory with proper permissions
print_message "📁 Creating k3s configuration directory..."
sudo mkdir -p /etc/rancher/k3s

# Copy our configuration file to the correct location
print_message "📝 Installing k3s configuration..."
cat << 'EOF' | sudo tee /etc/rancher/k3s/config.yaml
# Disable components we want to replace
disable:
  - traefik
  - servicelb

# Cluster networking configuration
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"

# Security settings
secrets-encryption: true

# Performance optimizations
kube-apiserver-arg:
  - "default-not-ready-toleration-seconds=10"
  - "default-unreachable-toleration-seconds=10"

# Storage location
data-dir: "/var/lib/rancher/k3s"

# Kubeconfig permissions
write-kubeconfig-mode: "0600"
EOF

print_message "📥 Installing k3s..."
# The key insight: k3s automatically reads from /etc/rancher/k3s/config.yaml
# We don't need to specify --config when the file is in this location
curl -sfL https://get.k3s.io | sh -

# Wait for k3s to be ready
print_message "⏳ Waiting for k3s to initialize..."
sleep 10

while ! sudo k3s kubectl get nodes >/dev/null 2>&1; do
    echo -n "."
    sleep 2
done
echo ""

# Verify that traefik and servicelb are NOT running
print_message "🔍 Verifying traefik and servicelb are disabled..."
sleep 5  # Give pods time to appear if they're going to

TRAEFIK_PODS=$(sudo k3s kubectl get pods -n kube-system | grep traefik || true)
SVCLB_PODS=$(sudo k3s kubectl get pods -A | grep svclb || true)

if [[ -z "$TRAEFIK_PODS" ]]; then
    print_success "✅ Traefik is successfully disabled"
else
    print_error "❌ Traefik pods found! Something went wrong."
    echo "$TRAEFIK_PODS"
fi

if [[ -z "$SVCLB_PODS" ]]; then
    print_success "✅ ServiceLB is successfully disabled"
else
    print_error "❌ ServiceLB pods found! Something went wrong."
    echo "$SVCLB_PODS"
fi

# Setup kubeconfig for user
print_message "📋 Setting up kubeconfig for user access..."
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config

# Update the server address to use actual IP instead of localhost
CURRENT_IP=$(ip route get 1 | awk '{print $7;exit}')
sed -i "s/127.0.0.1/$CURRENT_IP/g" ~/.kube/config

print_success "✅ k3s installation complete!"
print_message "📊 Cluster status:"
kubectl get nodes
kubectl get pods -A

print_message "📝 Next steps:"
echo "  1. Install MetalLB for load balancer support"
echo "  2. Install HAProxy or NGINX ingress controller"
echo "  3. Verify with: kubectl get pods -A"