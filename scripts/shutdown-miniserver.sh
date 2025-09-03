#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
NODE_NAME="miniserver"
GRACE_PERIOD=30
FORCE_TIMEOUT=180
LONGHORN_WAIT=180
DRY_RUN=false
ALLOW_SINGLE_REPLICA=false
LOG_DIR="/var/log/k8s-homelab"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME%.*}-$(date +%F-%H%M%S).log"
K3S_SERVER_SERVICE="k3s"

RED="$(printf '\033[31m')"; GREEN="$(printf '\033[32m')"; YELLOW="$(printf '\033[33m')"; BLUE="$(printf '\033[34m')"; PURPLE="$(printf '\033[35m')"; RESET="$(printf '\033[0m')"

log() { local level="$1"; shift; local msg="$*"; echo "[$(date +'%F %T')] [$level] $msg" | tee -a "$LOG_FILE"; }
info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }
step() { log "STEP" "==== $* ===="; }
dry() { log "DRY-RUN" "$@"; }

ensure_log_dir() { sudo mkdir -p "$LOG_DIR" && sudo touch "$LOG_FILE" && sudo chown "$(id -u)":"$(id -g)" "$LOG_FILE" || true; }

usage() {
  cat <<EOF
$SCRIPT_NAME - Graceful shutdown for control-plane node (miniserver)

IMPORTANT: For full cluster shutdown, run shutdown-worker-1.sh on worker first, then this script on miniserver.

Usage: sudo ./$SCRIPT_NAME [--node NAME] [--grace-period SECONDS] [--force-timeout SECONDS] [--longhorn-wait SECONDS] [--dry-run] [--allow-single-replica]

Options:
  --node NAME               Kubernetes node name to shut down (default: miniserver)
  --grace-period SECONDS    Pod termination grace period for drain (default: 30)
  --force-timeout SECONDS   Force deletion timeout for drain (default: 180)
  --longhorn-wait SECONDS   Max seconds to wait for Longhorn volumes to detach (default: 180)
  --dry-run                 Print actions without executing
  --allow-single-replica    Proceed even if some Longhorn volumes do NOT have a replica on worker-1 (NOT RECOMMENDED)
  -h, --help                Show this help
EOF
}

run() {
  if $DRY_RUN; then dry "$*"; else eval "$@"; fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error "This script must be run as root (sudo)."
    exit 1
  fi
}

require_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    error "kubectl not found in PATH."
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node) NODE_NAME="$2"; shift 2 ;;
      --grace-period) GRACE_PERIOD="$2"; shift 2 ;;
      --force-timeout) FORCE_TIMEOUT="$2"; shift 2 ;;
      --longhorn-wait) LONGHORN_WAIT="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --allow-single-replica) ALLOW_SINGLE_REPLICA=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done
}

confirm() {
  echo "About to gracefully shut down control-plane node: $NODE_NAME"
  echo "Options: grace=$GRACE_PERIOD, forceTimeout=$FORCE_TIMEOUT, longhornWait=$LONGHORN_WAIT, dryRun=$DRY_RUN"
  read -r -p "Type YES to proceed: " ans
  [[ "$ans" == "YES" ]]
}

node_exists() {
  kubectl get node "$NODE_NAME" >/dev/null 2>&1
}

argo_summary() {
  if ! kubectl get ns argocd >/dev/null 2>&1; then
    info "ArgoCD namespace not found; skipping Argo sync check."
    return 0
  fi
  local outOfSync
  outOfSync="$(kubectl -n argocd get applications.argoproj.io -o jsonpath='{range .items[?(@.status.sync.status!="Synced")]}{.metadata.name}{"\n"}{end}' || true)"
  if [[ -n "$outOfSync" ]]; then
    warn "ArgoCD apps out of sync (proceeding):"
    echo "$outOfSync" | tee -a "$LOG_FILE"
  else
    info "All ArgoCD apps are Synced."
  fi
}

longhorn_settings_snapshot() {
  if ! kubectl get ns longhorn-system >/dev/null 2>&1; then
    warn "Longhorn not detected; skipping Longhorn checks."
    return 1
  fi
  info "Longhorn settings (subset):"
  kubectl -n longhorn-system get settings.longhorn.io | grep -E 'default-replica-count|replica-auto-balance|replica-soft-anti-affinity|concurrent-replica-rebuild-per-node-limit|replica-replenishment-wait-interval' || true
}

longhorn_verify_replicas_on_worker() {
  if ! kubectl get ns longhorn-system >/dev/null 2>&1; then
    return 0
  fi
  if ! kubectl get node worker-1 >/dev/null 2>&1; then
    warn "worker-1 node not found; skipping replica placement check."
    return 0
  fi
  step "Checking Longhorn volume health and replica placement (expect at least one RW on worker-1)"
  local vols
  vols="$(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.numberOfReplicas}{"\t"}{.status.robustness}{"\n"}{end}' || true)"
  if [[ -z "$vols" ]]; then
    info "No Longhorn volumes found."
    return 0
  fi
  echo "VOLUME   REPLICAS   ROBUSTNESS" | tee -a "$LOG_FILE"
  echo "$vols" | awk -F'\t' '{printf "%-24s %-9s %-12s\n",$1,$2,$3}' | tee -a "$LOG_FILE"

  local replicas
  replicas="$(kubectl -n longhorn-system get replicas.longhorn.io -o jsonpath='{range .items[*]}{.spec.volumeName}{"\t"}{.spec.nodeID}{"\t"}{.status.mode}{"\n"}{end}' || true)"

  local missing_on_worker=0
  while IFS=$'\t' read -r vol nRep robust; do
    [[ -z "$vol" ]] && continue
    local has_w1_rw
    has_w1_rw="$(echo "$replicas" | awk -F'\t' -v v="$vol" '$1==v && $2=="worker-1" && $3=="RW"{print "yes"; exit}')"
    if [[ "$has_w1_rw" != "yes" ]]; then
      warn "Volume $vol does not have an RW replica on worker-1."
      missing_on_worker=$((missing_on_worker+1))
    fi
  done <<< "$vols"

  if [[ $missing_on_worker -gt 0 ]]; then
    if $ALLOW_SINGLE_REPLICA; then
      warn "$missing_on_worker volume(s) lack RW replica on worker-1. Proceeding due to --allow-single-replica."
    else
      warn "$missing_on_worker volume(s) lack RW replica on worker-1. If worker remains up during this shutdown, PVC availability may drop until miniserver returns."
    fi
  else
    info "All volumes have at least one RW replica on worker-1."
  fi
}

wait_for_longhorn_detach_all() {
  if ! kubectl get ns longhorn-system >/dev/null 2>&1; then
    return 0
  fi
  step "Waiting for all Longhorn volumes to detach (up to ${LONGHORN_WAIT}s)"
  local end=$((SECONDS + LONGHORN_WAIT))
  local remaining
  while :; do
    remaining="$(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.state}{"\n"}{end}' \
      | awk -F'\t' '$2!="detached"{print $1}' | wc -l | tr -d ' ')"
    if [[ "$remaining" -eq 0 ]]; then
      info "All Longhorn volumes are detached."
      break
    fi
    if (( SECONDS >= end )); then
      warn "Timeout waiting for Longhorn volumes to detach. Proceeding with shutdown."
      break
    fi
    info "Volumes still attached: $remaining; rechecking..."
    sleep 5
  done
}

kubectl_supports_disable_eviction() {
  kubectl drain --help 2>&1 | grep -q -- "--disable-eviction"
}

drain_node() {
  step "Cordoning node $NODE_NAME"
  run "kubectl cordon \"$NODE_NAME\""
  step "Ensuring worker-1 remains cordoned"
  run "kubectl cordon worker-1 || true"
  step "Draining node $NODE_NAME (ignore DaemonSets; force delete; prevent reschedule)"
  local extra=""
  if kubectl_supports_disable_eviction; then
    extra="--disable-eviction"
  else
    warn "kubectl does not support --disable-eviction; proceeding without it."
  fi
  run "kubectl drain \"$NODE_NAME\" --ignore-daemonsets --delete-emptydir-data --force --grace-period=$GRACE_PERIOD --timeout=${FORCE_TIMEOUT}s $extra"
}

stop_k3s_server() {
  step "Stopping k3s server service"
  run "systemctl stop $K3S_SERVER_SERVICE"
  if ! $DRY_RUN; then
    sleep 2
    if systemctl is-active --quiet "$K3S_SERVER_SERVICE"; then
      warn "k3s server still active, sending SIGTERM to process"
      run "pkill -TERM -f '^k3s server' || true"
      sleep 2
    fi
  fi
}

poweroff_host() {
  step "Flushing filesystems"
  run "sync"
  step "Powering off host"
  run "systemctl poweroff"
}

main() {
  ensure_log_dir
  parse_args "$@"
  require_root
  require_kubectl

  step "Pre-flight checks"
  if ! node_exists; then
    error "Kubernetes node '$NODE_NAME' not found. Use --node to set the correct name."
    exit 1
  fi
  info "OS hostname: $(hostname); Target K8s node: $NODE_NAME"
  info "Cluster API health check:"
  kubectl get --raw=/readyz >/dev/null 2>&1 && info "/readyz OK" || warn "/readyz unavailable"
  kubectl get --raw=/healthz >/dev/null 2>&1 && info "/healthz OK" || warn "/healthz unavailable"
  argo_summary
  longhorn_settings_snapshot
  longhorn_verify_replicas_on_worker

  step "User confirmation"
  if ! confirm; then
    info "Aborted by user."
    exit 0
  fi

  drain_node
  wait_for_longhorn_detach_all
  stop_k3s_server
  poweroff_host
}

main "$@"