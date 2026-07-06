#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-repro-bug}"
CLUSTER="${PG_CLUSTER:-pg-repro}"
CNPG_VERSION="${CNPG_VERSION:-1.29.2}"
BRANCH="release-${CNPG_VERSION%.*}"
MANIFEST="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${BRANCH}/releases/cnpg-${CNPG_VERSION}.yaml"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
[[ -n "${CLUSTER_NAME:-}" && -r "$(pwd)/${CLUSTER_NAME}-kubeconfig.yaml" ]] && export KUBECONFIG="$(pwd)/${CLUSTER_NAME}-kubeconfig.yaml"
k() { kubectl -n "$NS" "$@"; }

log "deleting repro resources"
k delete cluster "$CLUSTER" --ignore-not-found --wait=true
k delete backup --all --ignore-not-found
k delete volumesnapshot --all --ignore-not-found --timeout=60s
k delete pvc --all --ignore-not-found --wait=true

kubectl get pv -o jsonpath="{range .items[?(@.status.phase=='Released')]}{.metadata.name}{' '}{.spec.claimRef.namespace}{'\n'}{end}" \
  | awk -v ns="$NS" '$2==ns{print $1}' | xargs -r kubectl delete pv

kubectl get volumesnapshotcontent -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.volumeSnapshotRef.namespace}{"\n"}{end}' \
  | awk -v ns="$NS" '$2==ns{print $1}' | xargs -r kubectl delete volumesnapshotcontent

if [[ -n "${AZURE_STORAGE_ACCOUNT:-}" && -n "${AZURE_STORAGE_KEY:-}" && -n "${AZURE_BLOB_CONTAINER:-}" ]]; then
  if AZ_BIN="$(command -v az)"; then
    log "deleting archive blobs with ${AZ_BIN}"
    az storage blob delete-batch --account-name "$AZURE_STORAGE_ACCOUNT" --account-key "$AZURE_STORAGE_KEY" --source "$AZURE_BLOB_CONTAINER" --pattern '*' -o none
  else
    log "deleting archive blobs with embedded python"
    python3 - <<'PY'
import base64, hashlib, hmac, os, re, sys, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
acct=os.environ["AZURE_STORAGE_ACCOUNT"]; key=os.environ["AZURE_STORAGE_KEY"]; cont=os.environ["AZURE_BLOB_CONTAINER"]
def req(method, path, query=""):
    date=datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT"); url=f"https://{acct}.blob.core.windows.net{path}" + (f"?{query}" if query else "")
    p=urllib.parse.urlparse(url); canon=f"/{acct}{p.path}"; params=urllib.parse.parse_qs(p.query)
    for k in sorted(params): canon += f"\n{k}:{','.join(sorted(params[k]))}"
    hdr={"x-ms-date":date,"x-ms-version":"2021-08-06"}; s="\n".join([method,"","","","","","","","","","","","\n".join(f"{k}:{v}" for k,v in sorted(hdr.items())),canon])
    hdr["Authorization"]="SharedKey %s:%s"%(acct,base64.b64encode(hmac.new(base64.b64decode(key),s.encode(),hashlib.sha256).digest()).decode())
    return urllib.request.urlopen(urllib.request.Request(url, headers=hdr, method=method), timeout=30)
def blobs():
    out=[]; marker=""
    while True:
        q="restype=container&comp=list&maxresults=5000" + (f"&marker={urllib.parse.quote(marker)}" if marker else "")
        data=req("GET", f"/{cont}", q).read().decode(); out += re.findall(r"<Name>(.*?)</Name>", data); m=re.search(r"<NextMarker>(.*?)</NextMarker>", data)
        marker=m.group(1) if m and m.group(1) else ""
        if not marker: return out
names=blobs(); print(f"Found {len(names)} blobs in {cont}")
with ThreadPoolExecutor(max_workers=20) as ex:
    for f in as_completed(ex.submit(req, "DELETE", f"/{cont}/{urllib.parse.quote(n)}") for n in names): f.result()
remaining=blobs(); print(f"Remaining after cleanup: {len(remaining)}"); sys.exit(1 if remaining else 0)
PY
  fi
fi

log "deleting k8s support resources and operator"
kubectl delete volumesnapshotclass azure-disk --ignore-not-found
kubectl delete storageclass managed-premium-delete --ignore-not-found
kubectl delete ns "$NS" --ignore-not-found --wait=true
kubectl delete --ignore-not-found -f "$MANIFEST"

log "done"
