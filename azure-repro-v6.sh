#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-repro-bug}"
CLUSTER="${PG_CLUSTER:-pg-repro}"
CNPG_VERSION="${CNPG_VERSION:-1.29.2}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.20.3}"
BARMAN_PLUGIN_VERSION="${BARMAN_PLUGIN_VERSION:-v0.13.0}"
PG_IMAGE="${PG_IMAGE:-ghcr.io/cloudnative-pg/postgresql:18.4-202606221003-system-trixie@sha256:918ed523d6fa5572492afed43e1503bf6fba0b96f424f1a946ff7c4b67b152ce}"
PGBENCH_SCALE="${PGBENCH_SCALE:-28}"
BACKUP_MODE="${1:-${BACKUP_MODE:-plugin}}"
case "$BACKUP_MODE" in
  plugin|--plugin) BACKUP_MODE="plugin" ;;
  intree|in-tree|--intree|--in-tree) BACKUP_MODE="intree" ;;
  -h|--help) printf 'usage: %s [plugin|intree]\n' "$0"; exit 0 ;;
  *) printf 'usage: %s [plugin|intree]\n' "$0" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { printf 'usage: %s [plugin|intree]\n' "$0" >&2; exit 2; }
BARMAN_DEST="https://${AZURE_STORAGE_ACCOUNT:?}.blob.core.windows.net/${AZURE_BLOB_CONTAINER:?}/"
BARMAN_OBJECT="${BARMAN_OBJECT:-${CLUSTER}-store}"
BRANCH="release-${CNPG_VERSION%.*}"
MANIFEST="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${BRANCH}/releases/cnpg-${CNPG_VERSION}.yaml"
CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
BARMAN_PLUGIN_MANIFEST="https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${BARMAN_PLUGIN_VERSION}/manifest.yaml"
RUN_LOG_DIR="${RUN_LOG_DIR:-$(pwd)/run-logs}"
mkdir -p "$RUN_LOG_DIR"
RUN_LOG="${RUN_LOG:-${RUN_LOG_DIR}/v6-${BACKUP_MODE}-$(date -u +%Y%m%dT%H%M%SZ).log}"
exec > >(tee -a "$RUN_LOG") 2>&1

for d in /nix/store/x4wdpvg0gmlfs3m1c1kf625hjx2fqgwq-kubectl-cnpg-1.28.1/bin /nix/store/1kqhx3xmmrib204zlyanhadrvh0dj8l9-kubectl-cnpg-1.28.0/bin /home/ubuntu/projects/cloudnative-pg/bin; do
  [[ -x "$d/kubectl-cnpg" ]] && export PATH="$d:$PATH"
done

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "FATAL: $*" >&2; exit 1; }
[[ -n "${CLUSTER_NAME:-}" && -r "$(pwd)/${CLUSTER_NAME}-kubeconfig.yaml" ]] && export KUBECONFIG="$(pwd)/${CLUSTER_NAME}-kubeconfig.yaml"
k() { kubectl -n "$NS" "$@"; }
psql() { k exec "$1" -c postgres -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tAqc "$2" | tr -d '\r'; }
ready() { for i in $(seq 1 "${2:-240}"); do [[ "$(k get pod "$1" --ignore-not-found -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == True ]] && return 0; sleep 1; done; return 1; }

log "install CNPG ${CNPG_VERSION}"
kubectl apply --server-side -f "$MANIFEST"
kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=120s

log "install cert-manager ${CERT_MANAGER_VERSION} and Barman Cloud plugin ${BARMAN_PLUGIN_VERSION}"
kubectl apply -f "$CERT_MANAGER_MANIFEST"
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s
kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s
for i in $(seq 1 12); do
  kubectl apply -f "$BARMAN_PLUGIN_MANIFEST" && break
  [[ "$i" == 12 ]] && die "Barman Cloud plugin install failed"
  sleep 5
done
kubectl rollout status deployment/barman-cloud -n cnpg-system --timeout=180s

log "create storage classes, secret, object store, and one-instance cluster (${BACKUP_MODE})"
kubectl delete volumesnapshotclass azure-disk --ignore-not-found
kubectl apply -f - <<'YAML'
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: azure-disk
driver: disk.csi.azure.com
deletionPolicy: Delete
parameters:
  incremental: "true"
  instantAccessDurationMinutes: "300"
YAML

kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-premium-delete
provisioner: disk.csi.azure.com
parameters:
  skuName: PremiumV2_LRS
  cachingMode: None
volumeBindingMode: WaitForFirstConsumer
YAML

kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create secret generic azure-creds \
  --from-literal=AZURE_STORAGE_ACCOUNT="$AZURE_STORAGE_ACCOUNT" \
  --from-literal=AZURE_STORAGE_KEY="${AZURE_STORAGE_KEY:?}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" apply -f - <<EOF
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: ${BARMAN_OBJECT}
spec:
  configuration:
    destinationPath: "${BARMAN_DEST}"
    azureCredentials:
      storageAccount: {name: azure-creds, key: AZURE_STORAGE_ACCOUNT}
      storageKey: {name: azure-creds, key: AZURE_STORAGE_KEY}
    wal: {compression: gzip, maxParallel: 32}
EOF

if [[ "$BACKUP_MODE" == plugin ]]; then
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER}
spec:
  instances: 1
  imageName: ${PG_IMAGE}
  storage: {size: 30Gi, storageClass: managed-premium-delete}
  postgresql:
    parameters:
      autovacuum: "off"
      log_autovacuum_min_duration: "0"
  backup:
    volumeSnapshot: {className: azure-disk}
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: ${BARMAN_OBJECT}
EOF
else
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER}
spec:
  instances: 1
  imageName: ${PG_IMAGE}
  storage: {size: 30Gi, storageClass: managed-premium-delete}
  postgresql:
    parameters:
      autovacuum: "off"
      log_autovacuum_min_duration: "0"
  backup:
    volumeSnapshot: {className: azure-disk}
    barmanObjectStore:
      destinationPath: "${BARMAN_DEST}"
      azureCredentials:
        storageAccount: {name: azure-creds, key: AZURE_STORAGE_ACCOUNT}
        storageKey: {name: azure-creds, key: AZURE_STORAGE_KEY}
      wal: {compression: gzip, maxParallel: 32}
EOF
fi
kubectl wait cluster "$CLUSTER" -n "$NS" --for=condition=Ready --timeout=300s

PRIMARY="$(k get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}')"
[[ -n "$PRIMARY" ]] || die "no primary"
[[ "$PRIMARY" == "${CLUSTER}-1" ]] || die "run cleanup first"

BACKUP="${CLUSTER}-v6-snap-$(date -u +%Y%m%d%H%M%S)"
log "snapshot ${PRIMARY}"
k apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: {name: ${BACKUP}, namespace: ${NS}}
spec:
  method: volumeSnapshot
  cluster: {name: ${CLUSTER}}
EOF
for i in $(seq 1 180); do
  phase="$(k get backup "$BACKUP" --ignore-not-found -o jsonpath='{.status.phase}')"
  [[ "$phase" == completed ]] && break
  [[ "$phase" == failed ]] && die "backup failed"
  sleep 10
done
[[ "$(k get backup "$BACKUP" -o jsonpath='{.status.phase}')" == completed ]] || die "backup timeout"

log "pgbench scale ${PGBENCH_SCALE}"
k exec "$PRIMARY" -c postgres -- pgbench -i -s "$PGBENCH_SCALE" -U postgres postgres
psql "$PRIMARY" "UPDATE pgbench_accounts SET abalance = abalance + 1;"

log "pause autovacuum worker"
kubectl -n "$NS" patch cluster "$CLUSTER" --type merge -p '{"spec":{"postgresql":{"parameters":{"autovacuum":"on","log_autovacuum_min_duration":"0"}}}}'
AVPID=""
for i in $(seq 1 300); do
  AVPID="$(psql "$PRIMARY" "select pid from pg_stat_activity a join pg_locks l using(pid) where backend_type='autovacuum worker' and l.relation='public.pgbench_accounts'::regclass and l.mode='ShareUpdateExclusiveLock' and l.granted limit 1" | tr -d '[:space:]')"
  [[ -n "$AVPID" ]] && break
  sleep 1
done
[[ -n "$AVPID" ]] || die "no autovacuum worker"
k exec "$PRIMARY" -c postgres -- kill -STOP "$AVPID"

log "scale to 2 and promote snapshot replica"
kubectl -n "$NS" patch cluster "$CLUSTER" --type merge -p '{"spec":{"instances":2}}'
REPLICA="${CLUSTER}-2"
ready "$REPLICA" 240 || die "replica not ready"
psql "$PRIMARY" "select pg_switch_wal()"
kubectl cnpg promote "$CLUSTER" "$REPLICA" -n "$NS"

log "wait redo done, release autovacuum, write on new primary"
for i in $(seq 1 1200); do
  kubectl -n "$NS" logs "$REPLICA" -c postgres --since=20m | grep -q 'redo done at' && break
  [[ "$i" == 1200 ]] && die "redo timeout"
  sleep 0.5
done
k exec "$PRIMARY" -c postgres -- kill -CONT "$AVPID"
for i in $(seq 1 120); do [[ "$(psql "$REPLICA" 'select not pg_is_in_recovery()' | tr -d '[:space:]')" == t ]] && break; sleep 1; done
psql "$REPLICA" "select pg_switch_wal()"
psql "$REPLICA" "update pgbench_accounts set abalance=abalance+1 where aid=1 returning aid"

log "scale to 3 and watch for incorrect prev-link"
kubectl -n "$NS" patch cluster "$CLUSTER" --type merge -p '{"spec":{"instances":3}}'
VICTIM="${CLUSTER}-3"
seen_prev=0
for i in $(seq 1 360); do
  if logs="$(kubectl -n "$NS" logs "$VICTIM" -c postgres --since=10m 2>&1)"; then
    prev_count="$(printf '%s\n' "$logs" | awk '/incorrect prev-link/{n++} END{print n+0}')"
    if (( prev_count > seen_prev )); then
      printf '%s\n' "$logs" | awk -v seen="$seen_prev" '/incorrect prev-link/{n++; if(n>seen) print}'
      seen_prev="$prev_count"
    fi
    if (( prev_count >= 3 )); then
      log "reproduced on ${VICTIM}"
      k get cluster,pods
      exit 0
    fi
    printf '%s\n' "$logs" | grep -E 'contrecord|PANIC' && { log "reproduced on ${VICTIM}"; k get cluster,pods; exit 0; }
  else
    log "waiting for ${VICTIM} logs: ${logs}"
  fi
  sleep 5
done
die "incorrect prev-link did not repeat 3 times; logs: ${RUN_LOG}"
