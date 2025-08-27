#!/bin/bash
#
# k8s-homelab Graceful Reboot Script
# 
# This script performs a graceful maintenance reboot of a k3s cluster with proper
# Kubernetes cleanup, Longhorn storage synchronization, and ArgoCD verification.
#
# Usage: ./reboot.sh [OPTIONS]
# Options:
#   --force-timeout SECONDS    Override default force timeout (default: 120)
#   --grace-period SECONDS     Override default grace period (default: 30)
#   --dry-run                  Show what would be done without executing
#   --help                     Show this help message
#
# Author: k8s-homelab
# Version: 1.0.0
#

set -euo pipefail

# Script configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="/var/log/k8s-homelab"
LOG_FILE="${LOG_DIR}/reboot-$(date +%Y%m%d-%H%M%S).log"

# Default timeouts (in seconds)
DEFAULT_GRACE_PERIOD=30
DEFAULT_FORCE_TIMEOUT=120
DEFAULT_LONGHORN_WAIT=60
DEFAULT_ARGO_WAIT=300
DEFAULT_OVERALL_TIMEOUT=600

# Configuration variables
GRACE_PERIOD=${DEFAULT_GRACE_PERIOD}
FORCE_TIMEOUT=${DEFAULT_FORCE_TIMEOUT}
LONGHORN_WAIT=${DEFAULT_LONGHORN_WAIT}
ARGO_WAIT=${DEFAULT_ARGO_WAIT}
OVERALL_TIMEOUT=${DEFAULT_OVERALL_TIMEOUT}
DRY_RUN=false

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[INFO]${NC} ${timestamp} - $message" | tee -a "${LOG_FILE}"
}

log_warn() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[WARN]${NC} ${timestamp} - $message" | tee -a "${LOG_FILE}"
}

log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[ERROR]${NC} ${timestamp} - $message" | tee -a "${LOG_FILE}"
}

log_step() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}[STEP]${NC} ${timestamp} - $message" | tee -a "${LOG_FILE}"
}

log_success() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[SUCCESS]${NC} ${timestamp} - $message" | tee -a "${LOG_FILE}"
}

log_dry_run() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${PURPLE}[DRY-RUN]${NC} ${timestamp} - $message" | tee -a "${LOG_FILE}"
}

# Error handling
error_exit() {
    local message="$1"
    local exit_code="${2:-1}"
    log_error "$message"
    log_error "Aborting reboot sequence"
    exit "$exit_code"
}

# Cleanup function for script interruption
cleanup() {
    log_warn "Script interrupted. Cleaning up..."
    # Uncordon node if it was cordoned
    if [[ -f "/tmp/k8s-homelab-node-cordoned" ]]; then
        log_info "Uncordoning node..."
        kubectl uncordon miniserver || true
        rm -f "/tmp/k8s-homelab-node-cordoned"
    fi
    log_error "Reboot sequence was interrupted"
    exit 130
}

trap cleanup SIGINT SIGTERM

# Usage function
show_help() {
    cat << EOF
${SCRIPT_NAME} - k8s-homelab Graceful Reboot Script

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

DESCRIPTION:
    Performs a graceful maintenance reboot of the k3s cluster with proper
    Kubernetes cleanup, Longhorn storage synchronization, and ArgoCD verification.

OPTIONS:
    --force-timeout SECONDS    Override default force timeout (default: ${DEFAULT_FORCE_TIMEOUT})
    --grace-period SECONDS     Override default grace period (default: ${DEFAULT_GRACE_PERIOD})
    --dry-run                  Show what would be done without executing
    --help                     Show this help message

EXAMPLES:
    ${SCRIPT_NAME}                                    # Standard graceful reboot
    ${SCRIPT_NAME} --dry-run                          # Test run without actual reboot
    ${SCRIPT_NAME} --grace-period 60 --force-timeout 180  # Extended timeouts

NOTES:
    - This script must be run as root or with sudo
    - Ensure all critical data is backed up before running
    - The script creates detailed logs in ${LOG_DIR}
    - Use --dry-run to test the script logic without actually rebooting

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force-timeout)
                FORCE_TIMEOUT="$2"
                shift 2
                ;;
            --grace-period)
                GRACE_PERIOD="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error_exit "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

# Validate numeric arguments
validate_arguments() {
    if ! [[ "$GRACE_PERIOD" =~ ^[0-9]+$ ]] || [[ "$GRACE_PERIOD" -lt 10 ]]; then
        error_exit "Grace period must be a number >= 10 seconds"
    fi
    
    if ! [[ "$FORCE_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$FORCE_TIMEOUT" -lt 30 ]]; then
        error_exit "Force timeout must be a number >= 30 seconds"
    fi
    
    if [[ "$FORCE_TIMEOUT" -le "$GRACE_PERIOD" ]]; then
        error_exit "Force timeout must be greater than grace period"
    fi
}

# Setup logging
setup_logging() {
    if [[ "$DRY_RUN" == "false" ]]; then
        sudo mkdir -p "$LOG_DIR"
        sudo touch "$LOG_FILE"
        sudo chmod 644 "$LOG_FILE"
    else
        LOG_FILE="/dev/null"
    fi
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]] && [[ "$DRY_RUN" == "false" ]]; then
        error_exit "This script must be run as root (use sudo)"
    fi
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        error_exit "kubectl is not installed or not in PATH"
    fi
    
    # Setup kubeconfig for root access
    setup_kubeconfig
    
    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        error_exit "Cannot connect to Kubernetes cluster"
    fi
    
    log_success "Prerequisites check passed"
}

# Setup kubeconfig for root access
setup_kubeconfig() {
    log_info "Setting up kubeconfig for root access..."
    
    # If running as root, we need to find the correct kubeconfig
    if [[ $EUID -eq 0 ]]; then
        local original_user="${SUDO_USER:-}"
        
        # Try to use the original user's kubeconfig first
        if [[ -n "$original_user" && -f "/home/$original_user/.kube/config" ]]; then
            export KUBECONFIG="/home/$original_user/.kube/config"
            log_info "Using user kubeconfig: /home/$original_user/.kube/config"
        # Fallback to k3s system kubeconfig
        elif [[ -f "/etc/rancher/k3s/k3s.yaml" ]]; then
            export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
            log_info "Using k3s system kubeconfig: /etc/rancher/k3s/k3s.yaml"
        else
            error_exit "Cannot find accessible kubeconfig file"
        fi
    fi
}

# User confirmation
get_user_confirmation() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Skipping user confirmation in dry-run mode"
        return 0
    fi
    
    echo
    echo -e "${WHITE}===============================================${NC}"
    echo -e "${WHITE}    k8s-homelab GRACEFUL REBOOT SCRIPT${NC}"
    echo -e "${WHITE}===============================================${NC}"
    echo
    echo -e "${YELLOW}⚠️  WARNING: This script will reboot your system!${NC}"
    echo
    echo "This script will perform the following actions:"
    echo "  1. Verify cluster and storage health"
    echo "  2. Check ArgoCD application sync status"
    echo "  3. Gracefully shutdown all applications"
    echo "  4. Cordon node and evict pods"
    echo "  5. Detach Longhorn storage volumes"
    echo "  6. Stop k3s services"
    echo "  7. Sync filesystems and reboot"
    echo
    echo "Configuration:"
    echo "  - Grace period: ${GRACE_PERIOD} seconds"
    echo "  - Force timeout: ${FORCE_TIMEOUT} seconds"
    echo "  - Longhorn wait: ${LONGHORN_WAIT} seconds"
    echo "  - ArgoCD wait: ${ARGO_WAIT} seconds"
    echo
    echo -e "${YELLOW}Make sure all critical data is backed up!${NC}"
    echo
    
    while true; do
        read -p "Do you want to continue with the reboot? (yes/no): " -r response
        case $response in
            [Yy][Ee][Ss]|[Yy])
                log_info "User confirmed reboot sequence"
                break
                ;;
            [Nn][Oo]|[Nn])
                log_info "User cancelled reboot sequence"
                exit 0
                ;;
            *)
                echo "Please answer yes or no."
                ;;
        esac
    done
}

# Check cluster health
check_cluster_health() {
    log_step "Checking cluster health..."
    
    # Check node status
    local node_status=$(kubectl get nodes --no-headers | awk '{print $2}')
    if [[ "$node_status" != "Ready" ]]; then
        error_exit "Node is not in Ready state: $node_status"
    fi
    
    # Check for failing pods
    local failing_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Succeeded,status.phase!=Running --no-headers | wc -l)
    if [[ "$failing_pods" -gt 0 ]]; then
        log_warn "Found $failing_pods pods not in Running/Succeeded state"
        kubectl get pods --all-namespaces --field-selector=status.phase!=Succeeded,status.phase!=Running
        echo
        read -p "Continue anyway? (yes/no): " -r response
        if [[ ! "$response" =~ ^[Yy][Ee][Ss]$|^[Yy]$ ]]; then
            error_exit "Aborting due to unhealthy pods"
        fi
    fi
    
    # Check system resources
    local available_memory=$(free -m | awk '/^Mem:/{print $7}')
    if [[ "$available_memory" -lt 500 ]]; then
        log_warn "Low available memory: ${available_memory}MB"
    fi
    
    log_success "Cluster health check passed"
}

# Check ArgoCD sync status
check_argocd_sync() {
    log_step "Checking ArgoCD application sync status..."
    
    # Check if ArgoCD is available
    if ! kubectl get namespace argocd &> /dev/null; then
        log_warn "ArgoCD namespace not found, skipping sync check"
        return 0
    fi
    
    # Check if argocd CLI is available
    if ! command -v argocd &> /dev/null; then
        log_warn "ArgoCD CLI not found, skipping detailed sync check"
        return 0
    fi
    
    # Get application sync status
    local out_of_sync_apps=$(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.sync.status}{"\n"}{end}' | grep -v "Synced" | wc -l)
    
    if [[ "$out_of_sync_apps" -gt 0 ]]; then
        log_warn "Found $out_of_sync_apps applications that are not synced"
        kubectl get applications -n argocd -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status"
        echo
        read -p "Continue with reboot anyway? (yes/no): " -r response
        if [[ ! "$response" =~ ^[Yy][Ee][Ss]$|^[Yy]$ ]]; then
            error_exit "Aborting due to out-of-sync applications"
        fi
    fi
    
    log_success "ArgoCD sync check completed"
}

# Check Longhorn storage health
check_longhorn_health() {
    log_step "Checking Longhorn storage health..."
    
    # Check if Longhorn is available
    if ! kubectl get namespace longhorn-system &> /dev/null; then
        log_warn "Longhorn namespace not found, skipping storage health check"
        return 0
    fi
    
    # Check Longhorn manager pods
    local longhorn_pods_ready=$(kubectl get pods -n longhorn-system -l app=longhorn-manager --no-headers | awk '{print $2}' | grep -c "2/2" || true)
    local total_longhorn_pods=$(kubectl get pods -n longhorn-system -l app=longhorn-manager --no-headers | wc -l)
    
    if [[ "$longhorn_pods_ready" -ne "$total_longhorn_pods" ]]; then
        error_exit "Longhorn manager pods not ready: $longhorn_pods_ready/$total_longhorn_pods"
    fi
    
    # Check volume health
    local unhealthy_volumes=$(kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.state}{"\n"}{end}' | grep -v "attached\|detached" | wc -l || true)
    
    if [[ "$unhealthy_volumes" -gt 0 ]]; then
        log_warn "Found $unhealthy_volumes unhealthy Longhorn volumes"
        kubectl get volumes.longhorn.io -n longhorn-system -o custom-columns="NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"
        echo
        read -p "Continue with reboot anyway? (yes/no): " -r response
        if [[ ! "$response" =~ ^[Yy][Ee][Ss]$|^[Yy]$ ]]; then
            error_exit "Aborting due to unhealthy Longhorn volumes"
        fi
    fi
    
    log_success "Longhorn storage health check passed"
}

# Cordon node
cordon_node() {
    log_step "Cordoning node to prevent new pod scheduling..."
    
    local node_name="miniserver"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would cordon node: $node_name"
        return 0
    fi
    
    if kubectl cordon "$node_name"; then
        touch "/tmp/k8s-homelab-node-cordoned"
        log_success "Node $node_name cordoned successfully"
    else
        error_exit "Failed to cordon node $node_name"
    fi
}

# Gracefully evict pods
evict_pods() {
    log_step "Evicting pods with grace period of ${GRACE_PERIOD} seconds..."
    
    local node_name="miniserver"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would evict all pods from node: $node_name"
        log_dry_run "Grace period: ${GRACE_PERIOD}s, Force timeout: ${FORCE_TIMEOUT}s"
        return 0
    fi
    
    # Get pods running on this node (excluding DaemonSets and completed pods)
    local pods_to_evict=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' \
        | grep -v "kube-system.*" | grep -v "longhorn-system.*" || true)
    
    if [[ -z "$pods_to_evict" ]]; then
        log_info "No user pods found to evict"
        return 0
    fi
    
    log_info "Evicting $(echo "$pods_to_evict" | wc -l) pods..."
    
    # Start graceful eviction
    echo "$pods_to_evict" | while read -r pod; do
        if [[ -n "$pod" ]]; then
            local namespace=$(echo "$pod" | cut -d'/' -f1)
            local podname=$(echo "$pod" | cut -d'/' -f2)
            log_info "Evicting pod: $namespace/$podname"
            kubectl delete pod "$podname" -n "$namespace" --grace-period="$GRACE_PERIOD" &
        fi
    done
    
    # Wait for graceful termination
    log_info "Waiting ${GRACE_PERIOD} seconds for graceful termination..."
    sleep "$GRACE_PERIOD"
    
    # Force delete remaining pods
    local remaining_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' \
        | grep -v "kube-system.*" | grep -v "longhorn-system.*" || true)
    
    if [[ -n "$remaining_pods" ]]; then
        log_warn "Force deleting remaining pods after grace period..."
        echo "$remaining_pods" | while read -r pod; do
            if [[ -n "$pod" ]]; then
                local namespace=$(echo "$pod" | cut -d'/' -f1)
                local podname=$(echo "$pod" | cut -d'/' -f2)
                log_info "Force deleting pod: $namespace/$podname"
                kubectl delete pod "$podname" -n "$namespace" --grace-period=0 --force &
            fi
        done
        
        # Wait for force deletion
        sleep 10
    fi
    
    log_success "Pod eviction completed"
}

# Wait for Longhorn volume detachment
wait_longhorn_detachment() {
    log_step "Waiting for Longhorn volume detachment..."
    
    if ! kubectl get namespace longhorn-system &> /dev/null; then
        log_warn "Longhorn namespace not found, skipping volume detachment wait"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would wait for Longhorn volumes to detach (max ${LONGHORN_WAIT}s)"
        return 0
    fi
    
    local timeout=$LONGHORN_WAIT
    local start_time=$(date +%s)
    
    while [[ $timeout -gt 0 ]]; do
        local attached_volumes=$(kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.status.state}{"\n"}{end}' | grep -c "attached" || true)
        
        if [[ "$attached_volumes" -eq 0 ]]; then
            log_success "All Longhorn volumes detached"
            return 0
        fi
        
        log_info "Waiting for $attached_volumes volumes to detach... (${timeout}s remaining)"
        sleep 5
        timeout=$((timeout - 5))
    done
    
    local still_attached=$(kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.state}{"\n"}{end}' | grep "attached" || true)
    if [[ -n "$still_attached" ]]; then
        log_warn "Some volumes still attached after timeout:"
        echo "$still_attached"
        echo
        read -p "Continue with reboot anyway? (yes/no): " -r response
        if [[ ! "$response" =~ ^[Yy][Ee][Ss]$|^[Yy]$ ]]; then
            error_exit "Aborting due to attached Longhorn volumes"
        fi
    fi
}

# Shutdown k3s services
shutdown_k3s() {
    log_step "Shutting down k3s services gracefully..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would stop k3s service"
        return 0
    fi
    
    # Stop k3s service
    if systemctl is-active --quiet k3s; then
        log_info "Stopping k3s service..."
        systemctl stop k3s
        sleep 5
        
        # Verify it's stopped
        if systemctl is-active --quiet k3s; then
            log_warn "k3s service still running, forcing stop..."
            systemctl kill k3s
            sleep 3
        fi
    fi
    
    # Kill any remaining k3s processes
    local k3s_pids=$(pgrep k3s || true)
    if [[ -n "$k3s_pids" ]]; then
        log_info "Killing remaining k3s processes..."
        pkill -TERM k3s || true
        sleep 5
        pkill -KILL k3s || true
    fi
    
    log_success "k3s services stopped"
}

# Sync filesystems
sync_filesystems() {
    log_step "Syncing filesystems and flushing buffers..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would sync filesystems and flush buffers"
        return 0
    fi
    
    # Sync filesystems
    log_info "Syncing filesystems..."
    sync
    
    # Drop caches
    log_info "Dropping caches..."
    echo 3 > /proc/sys/vm/drop_caches
    
    # Final sync
    sync
    
    log_success "Filesystem sync completed"
}

# Final system verification
final_verification() {
    log_step "Performing final system verification..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would perform final system verification"
        return 0
    fi
    
    # Check for any remaining k3s processes
    local remaining_k3s=$(pgrep k3s || true)
    if [[ -n "$remaining_k3s" ]]; then
        log_warn "Found remaining k3s processes: $remaining_k3s"
    else
        log_success "No remaining k3s processes found"
    fi
    
    # Check mount points
    local k3s_mounts=$(mount | grep -E "(k3s|kubelet)" || true)
    if [[ -n "$k3s_mounts" ]]; then
        log_warn "Found remaining k3s mount points:"
        echo "$k3s_mounts"
    else
        log_success "No remaining k3s mount points found"
    fi
    
    log_success "Final verification completed"
}

# Execute reboot
execute_reboot() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry_run "Would execute system reboot now"
        log_info "Dry run completed successfully!"
        return 0
    fi
    
    log_step "Executing system reboot..."
    log_info "System will reboot now!"
    
    # Clean up our cordon marker
    rm -f "/tmp/k8s-homelab-node-cordoned"
    
    # Execute reboot
    /sbin/reboot
}

# Main execution function
main() {
    local start_time=$(date +%s)
    
    # Parse arguments
    parse_arguments "$@"
    validate_arguments
    setup_logging
    
    log_info "Starting k8s-homelab graceful reboot sequence"
    log_info "Configuration: grace-period=${GRACE_PERIOD}s, force-timeout=${FORCE_TIMEOUT}s, dry-run=${DRY_RUN}"
    
    # Main execution sequence
    check_prerequisites
    get_user_confirmation
    check_cluster_health
    check_argocd_sync
    check_longhorn_health
    cordon_node
    evict_pods
    wait_longhorn_detachment
    shutdown_k3s
    sync_filesystems
    final_verification
    execute_reboot
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "Dry run completed successfully in ${duration} seconds"
    else
        log_success "Graceful reboot sequence completed in ${duration} seconds"
    fi
}

# Execute main function with all arguments
main "$@"