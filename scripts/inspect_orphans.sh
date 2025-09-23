#!/usr/bin/env bash
# Idempotent orphan inspector launcher (v2)
set -uo pipefail   # no -e so we continue on individual failures

# --- Config ---
NS="default"
TARGET_NODE="miniserver"
REPLICAS_HOSTPATH="/srv/longhorn/replicas"   # host path on the node
ENGINE_IMAGE="longhornio/longhorn-engine:v1.9.1"
OUTDIR="/tmp/inspectors"
RUN_ID="$(date +%s)"                         # unique per run for device names
# --------------

mkdir -p "${OUTDIR}"

echo "==> Cleaning previous run (pods & lister) and waiting..."
kubectl -n "${NS}" delete pod -l app=orphan-inspect --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "${NS}" delete pod orphan-lister --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo "==> Creating lister pod on node '${TARGET_NODE}' to enumerate orphan replicas..."
kubectl -n "${NS}" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: orphan-lister
  labels:
    app: orphan-lister
spec:
  nodeName: ${TARGET_NODE}
  restartPolicy: Never
  containers:
  - name: lister
    image: alpine:3.20
    command: ["/bin/sh","-lc"]
    args:
      - |
        set -euo pipefail
        for d in /replicas/*; do
          [ -d "\$d" ] || continue
          meta="\$d/volume.meta"
          [ -f "\$meta" ] || continue
          size=\$(sed -n 's/.*"Size":[[:space:]]*\([0-9]\+\).*/\1/p' "\$meta" | head -n1)
          [ -n "\$size" ] || continue
          echo "\$(basename "\$d")|\$size"
        done
        # stay up so logs are readable
        sleep 3600
    volumeMounts:
    - name: replicas
      mountPath: /replicas
  volumes:
  - name: replicas
    hostPath:
      path: ${REPLICAS_HOSTPATH}
      type: Directory
EOF

echo "==> Waiting for orphan-lister to be Ready..."
kubectl -n "${NS}" wait --for=condition=Ready --timeout=90s pod/orphan-lister >/dev/null || {
  echo "!! orphan-lister not Ready; describe:" >&2
  kubectl -n "${NS}" describe pod orphan-lister >&2 || true
  exit 1
}

echo "==> Collecting orphan list..."
mapfile -t LINES < <(kubectl -n "${NS}" logs orphan-lister | sed '/^\s*$/d')

if (( ${#LINES[@]} == 0 )); then
  echo "No orphan replicas found under ${REPLICAS_HOSTPATH} on node ${TARGET_NODE}."
  echo "Cleanup: kubectl -n ${NS} delete pod orphan-lister || true"
  exit 0
fi

echo "==> Found ${#LINES[@]} orphan replicas. Creating inspector pods (RUN_ID=${RUN_ID})…"
idx=0
created=0
failed=0
declare -a MAP

for line in "${LINES[@]}"; do
  IFS='|' read -r BASENAME SIZE <<<"$line"
  if [[ -z "${BASENAME:-}" || -z "${SIZE:-}" ]]; then
    echo "!! Skipping malformed line: '$line'" >&2
    continue
  fi

  idx=$((idx+1))
  POD="orphan-inspect-${idx}"
  VOL="inspect-${idx}-${RUN_ID}"      # <--- unique device name per run
  REPL_DIR_HOST="${REPLICAS_HOSTPATH}/${BASENAME}"
  GiB=$(( SIZE / 1073741824 ))

  MAP+=("${POD}: ${BASENAME}  size=${SIZE} bytes (~${GiB} GiB)  device=/dev/longhorn/${VOL}")

  MAN="${OUTDIR}/${POD}.yaml"
  cat > "${MAN}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels:
    app: orphan-inspect
spec:
  nodeName: ${TARGET_NODE}
  restartPolicy: Never
  hostPID: true
  containers:
  - name: inspector
    image: ${ENGINE_IMAGE}
    imagePullPolicy: IfNotPresent
    securityContext:
      privileged: true
    volumeMounts:
    - name: dev
      mountPath: /host/dev
    - name: proc
      mountPath: /host/proc
    - name: replica
      mountPath: /volume
    command: ["/bin/sh","-lc"]
    args:
      - |
        set -euo pipefail
        VOL="${VOL}"
        SIZE="${SIZE}"
        SRC="${BASENAME}"
        echo "Launching Longhorn exporter for \${VOL} (\${SIZE} bytes) from \${SRC} (RUN_ID ${RUN_ID})..."
        launch-simple-longhorn "\${VOL}" "\${SIZE}" &
        # Wait for a STABLE device: must exist for 3 consecutive checks
        DEV="/host/dev/longhorn/\${VOL}"
        stable=0
        for t in \$(seq 1 180); do
          if [ -e "\$DEV" ]; then
            ok=1
            for _ in 1 2 3; do
              sleep 1
              [ -e "\$DEV" ] || { ok=0; break; }
            done
            if [ "\$ok" -eq 1 ]; then stable=1; break; fi
          fi
          sleep 1
        done
        if [ "\$stable" -ne 1 ]; then
          echo "ERROR: \$DEV never became stable"
          sleep 3600
        fi
        mkdir -p /mnt/src
        # Mount with retries to tolerate frontend toggles
        mounted=0
        for a in \$(seq 1 10); do
          if mount -o ro "\$DEV" /mnt/src; then
            mounted=1
            break
          fi
          echo "WARN: mount attempt \$a failed; re-checking device..."
          sleep 2
          # re-check stability quickly
          ok=1
          for _ in 1 2 3; do
            sleep 1
            [ -e "\$DEV" ] || { ok=0; break; }
          done
          [ "\$ok" -eq 1 ] || echo "WARN: device disappeared during retry"
        done
        if [ "\$mounted" -ne 1 ]; then
          echo "ERROR: failed to mount \$DEV after retries; leaving pod for inspection"
          sleep 3600
        fi

        echo "Filesystem summary:"; df -hT /mnt/src || true
        echo "Top-level sizes:"; du -sh /mnt/src/* 2>/dev/null | sort -h | tail -n 20 || true
        echo "Quick fingerprints:"
        test -f /mnt/src/PG_VERSION && echo "looks like Postgres"
        test -d /mnt/src/global && test -d /mnt/src/base && echo "postgres dir layout"
        test -f /mnt/src/ibdata1 && echo "mysql/mariadb"
        test -f /mnt/src/config/config.php && echo "nextcloud"
        test -f /mnt/src/appendonly.aof && echo "redis"
        echo "Device path: \$DEV"
        echo "Sleeping for shell access..."; sleep 3600
  volumes:
  - name: dev
    hostPath:
      path: /dev
  - name: proc
    hostPath:
      path: /proc
  - name: replica
    hostPath:
      path: ${REPL_DIR_HOST}
      type: Directory
EOF

  echo "-> Applying ${POD} (device ${VOL}) …"
  if out=$(kubectl -n "${NS}" apply -f "${MAN}" 2>&1); then
    echo "   ${out}"
    created=$((created+1))
  else
    echo "!! Failed to create ${POD}: ${out}" >&2
    echo "   Manifest saved at: ${MAN}" >&2
    failed=$((failed+1))
  fi
done

echo
echo "==== Mapping (pod -> replica dir, EXACT size, device) ===="
printf '%s\n' "${MAP[@]}"
echo "=========================================================="
echo
echo "Requested: ${idx}, Created: ${created}, Failed: ${failed}"
echo
echo "Check pods:"
echo "  kubectl -n ${NS} get pods -l app=orphan-inspect -o wide"
echo "  kubectl -n ${NS} logs orphan-inspect-1"
echo "  kubectl -n ${NS} exec -it orphan-inspect-1 -- /bin/sh"
echo
echo "Manifests are in ${OUTDIR}"
echo
echo "Cleanup:"
echo "  kubectl -n ${NS} delete pod orphan-lister"
echo "  kubectl -n ${NS} delete pod -l app=orphan-inspect"