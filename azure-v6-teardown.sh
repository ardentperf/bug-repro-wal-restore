#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-cnpgrepro6}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RG="${CLUSTER_NAME}-rg"

echo "deleting resource group ${RG}"
az group delete -n "$RG" --yes --no-wait
rm -f "${SCRIPT_DIR}/${CLUSTER_NAME}-v6.env" "${SCRIPT_DIR}/${CLUSTER_NAME}-kubeconfig.yaml"
echo "delete started"
