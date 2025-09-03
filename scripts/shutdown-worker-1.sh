#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
NODE_NAME="worker-1"
GRACE_PERIOD=30
FORCE_TIMEOUT=120
DRY_RUN=false
ALLOW_SINGLE_REPLICA=false
LOG_DIR="/var/log/k8s-homelab"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME%.*}-$(date +%F-%H%M%S).log"
K3S_AGENT_SERVICE="k3s-agent"

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
$SCRIPT_NAME - Graceful shutdown for worker node (worker-1)

Usage: sudo ./$SCRIPT_NAME [--node NAME] [--grace-period SECONDS] [--force-timeout SECONDS] [--dry-run] [--allow-single-replica]

Options:
  --node NAME               Kubernetes node name to shut down (default: worker-1)
  --grace-period SECONDS    Pod termination grace period for drain (default: 30)
  --force-timeout SECONDS   Force deletion timeout for drain (default: 120)
  --dry-run                 Print actions without executing
  --allow-single-replica    Proceed even if some Longhorn volumes have a single replica (NOT RECOMMENDED)
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
      --dry-run) DRY_RUN=true; shift ;;
      --allow-single-replica) ALLOW_SINGLE_REPLICA=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done
}

confirm() {
  echo "About to gracefully shut down node: $NODE_NAME"
  echo "Options: grace=$GRACE_PERIOD, forceTimeout=$FORCE_TIMEOUT, dryRun=$DRY_RUN"
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

longhorn_verify_replicas_on_miniserver() {
  if ! kubectl get ns longhorn-system >/dev/null 2>&1; then
    return 0
  fi
  step "Checking Longhorn volume health and replica placement"
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

  local missing_on_miniserver=0
  while IFS=$'\t' read -r vol nRep robust; do
    [[ -z "$vol" ]] && continue
    # Skip detached/inactive volumes from strict check
    local has_ms_rw
    has_ms_rw="$(echo "$replicas" | awk -F'\t' -v v="$vol" '$1==v && $2=="miniserver" && $3=="RW"{print "yes"; exit}')"
    if [[ "$has_ms_rw" != "yes" ]]; then
      warn "Volume $vol does not have an RW replica on miniserver."
      missing_on_miniserver=$((missing_on_miniserver+1))
    fi
  done <<< "$vols"

  if [[ $missing_on_miniserver -gt 0 ]]; then
    if $ALLOW_SINGLE_REPLICA; then
      warn "$missing_on_miniserver volume(s) lack RW replica on miniserver. Proceeding due to --allow-single-replica."
    else
      warn "$missing_on_miniserver volume(s) lack RW replica on miniserver. Continuing shutdown of worker is generally safe, but data redundancy will be reduced during maintenance."
    fi
  else
    info "All volumes have at least one RW replica on miniserver."
  fi
}

drain_node() {
  step "Cordoning node $NODE_NAME"
  run "kubectl cordon \"$NODE_NAME\""
  step "Draining node $NODE_NAME (ignore DaemonSets)"
  run "kubectl drain \"$NODE_NAME\" --ignore-daemonsets --delete-emptydir-data --force --grace-period=$GRACE_PERIOD --timeout=${FORCE_TIMEOUT}s"
}

stop_k3s_agent() {
  step "Stopping k3s agent service"
  run "systemctl stop $K3S_AGENT_SERVICE"
  if ! $DRY_RUN; then
    sleep 2
    if systemctl is-active --quiet "$K3S_AGENT_SERVICE"; then
      warn "k3s agent still active, sending SIGTERM to process"
      run "pkill -TERM -f 'k3s agent' || true"
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
  argo_summary
  longhorn_settings_snapshot
  longhorn_verify_replicas_on_miniserver

  step "User confirmation"
  if ! confirm; then
    info "Aborted by user."
    exit 0
  fi

  drain_node
  stop_k3s_agent
  poweroff_host
}

main "$@"