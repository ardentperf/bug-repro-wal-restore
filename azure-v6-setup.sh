#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-cnpgrepro6}"
LOCATION="${2:-westus3}"
RG="${CLUSTER_NAME}-rg"
SA="$(printf '%ssa' "${CLUSTER_NAME//-/}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-24)"
CONTAINER="$(printf '%s-barman' "$CLUSTER_NAME" | tr '[:upper:]' '[:lower:]')"
KUBECONFIG_FILE="$(pwd)/${CLUSTER_NAME}-kubeconfig.yaml"
CREDS_FILE="$(pwd)/${CLUSTER_NAME}-v6.env"
K8S_VERSION="${K8S_VERSION:-1.36}"
NODE_TYPE="${NODE_TYPE:-Standard_D2s_v3}"
NODE_COUNT="${NODE_COUNT:-2}"

need() { command -v "$1" || { echo "missing $1" >&2; exit 1; }; }
need az

echo "creating ${RG} in ${LOCATION}"
az group create -n "$RG" -l "$LOCATION" -o none

for provider in Microsoft.Storage Microsoft.ContainerService; do
  [[ "$(az provider show --namespace "$provider" --query registrationState -o tsv)" == Registered ]] \
    || az provider register --namespace "$provider" --wait
done

echo "creating storage ${SA}/${CONTAINER}"
az storage account create -g "$RG" -n "$SA" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false -o none
KEY="$(az storage account keys list -g "$RG" -n "$SA" --query '[0].value' -o tsv)"
az storage container create -n "$CONTAINER" --account-name "$SA" --account-key "$KEY" -o none

echo "creating AKS ${CLUSTER_NAME}"
ZONES="$(az vm list-skus -l "$LOCATION" --size "$NODE_TYPE" --query '[0].locationInfo[0].zones' -o tsv | tr '\t' ' ')"
[[ -n "$ZONES" && "$ZONES" != None ]] || { echo "no zones for ${NODE_TYPE} in ${LOCATION}" >&2; exit 1; }
AKS_ARGS=(-g "$RG" -n "$CLUSTER_NAME" -l "$LOCATION" --kubernetes-version "$K8S_VERSION" --node-count "$NODE_COUNT" --node-vm-size "$NODE_TYPE" --node-osdisk-type Managed --generate-ssh-keys --zones)
for z in $ZONES; do AKS_ARGS+=("$z"); done
az aks create "${AKS_ARGS[@]}" -o none

az aks get-credentials -g "$RG" -n "$CLUSTER_NAME" --admin --file "$KUBECONFIG_FILE" --overwrite-existing
chmod 600 "$KUBECONFIG_FILE"

cat > "$CREDS_FILE" <<EOF
export CLUSTER_NAME=${CLUSTER_NAME}
export RESOURCE_GROUP=${RG}
export KUBECONFIG="\$(pwd)/${CLUSTER_NAME}-kubeconfig.yaml"
export AZURE_STORAGE_ACCOUNT=${SA}
export AZURE_STORAGE_KEY='${KEY}'
export AZURE_BLOB_CONTAINER=${CONTAINER}
EOF
chmod 600 "$CREDS_FILE"

echo "wrote ${CREDS_FILE}"
echo "next: source ${CREDS_FILE} && bash azure-repro-v6.sh"
