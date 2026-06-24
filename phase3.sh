#!/bin/bash
# ==============================================================================
# Script: phase3.sh
# Purpose: Gathers cluster sizing/networking details via UI and uses native 
#          NKP automation to seamlessly deploy the air-gapped cluster.
#          (Updated for Docker Permission Checks & Secure Harbor Integration)
# ==============================================================================

set -euo pipefail

# FIX 1: Force 256-color support for 'gum' menus
export TERM="xterm-256color"

# ==============================================================================
# STEP 0: LOAD & CHECK PREREQUISITES
# ==============================================================================
gum style --foreground 212 -- "--- Checking Prerequisites ---"

# Proactive Docker Permission Check!
if ! docker info >/dev/null 2>&1; then
    echo ""
    gum style --foreground 196 "❌ ERROR: Docker Permission Denied!"
    gum style --foreground 226 "It looks like you forgot to log out and log back in after Phase 1."
    gum style --foreground 240 "To apply your new Docker permissions and fix this immediately, either:"
    gum style --foreground 250 "  1. Type 'exit' to disconnect, SSH back in, and rerun Phase 3."
    gum style --foreground 250 "  2. Run the command 'newgrp docker' in this terminal, then rerun Phase 3."
    echo ""
    exit 1
fi

if [ -f ".nkp_version.env" ] && [ -f ".nkp_image.env" ] && [ -f ".nkp_registry.env" ]; then
    source .nkp_version.env
    source .nkp_image.env
    source .nkp_registry.env
    export PATH="$PWD/nkp-${NKP_VERSION}/cli:$PATH"
    gum style --foreground 82 "✔ Found NKP Version: ${NKP_VERSION}"
    gum style --foreground 82 "✔ Found Target Image: ${IMAGE_NAME}"
    gum style --foreground 82 "✔ Found Harbor Registry: ${REGISTRY_URL}"
else
    gum style --foreground 196 "❌ ERROR: Missing environment files. Please ensure Phase 1 and Phase 2 completed successfully."
    exit 1
fi

if [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
    gum style --foreground 196 "❌ ERROR: SSH Public Key not found at $HOME/.ssh/id_rsa.pub. Please run Phase 1 or generate a key."
    exit 1
fi

# --- Default Variables ---
export CLUSTER_NAME="nkp-prod-01"
export PC_ENDPOINT="10.0.0.43" 
export NUTANIX_USER="admin"
export NUTANIX_PASSWORD=""
export PE_CLUSTER="PE_Cluster_Name"
export SUBNET_NAME="Default-Network" 
export STORAGE_CONTAINER="Default_Container"
export CONTROL_PLANE_VIP="10.0.0.50"
export METALLB_IP_RANGE="10.0.0.100-10.0.0.150"
export CONTROL_PLANE_REPLICAS="3"
export WORKER_REPLICAS="3"

# ==============================================================================
# STEP 1: LOAD CACHE & INTERACTIVE CONFIGURATION
# ==============================================================================
rm -f .nkp_cluster.env

CACHE_FILE=".nkp_phase3_cache.env"
if [ -f "$CACHE_FILE" ]; then
    gum style --foreground 240 "Loading previous configuration cache..."
    source "$CACHE_FILE"
    sleep 1
fi

clear

gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "NKP Phase 3: Nutanix Cluster Deployment"

gum style --foreground 99 -- "--- Cluster Identity & Sizing ---"
INPUT_CLUSTER=$(gum input --prompt "Cluster Name: " --placeholder "${CLUSTER_NAME}")
export CLUSTER_NAME="${INPUT_CLUSTER:-${CLUSTER_NAME}}"

INPUT_VIP=$(gum input --prompt "Control Plane VIP (Unused IP): " --placeholder "${CONTROL_PLANE_VIP}")
export CP_VIP="${INPUT_VIP:-${CONTROL_PLANE_VIP}}"

INPUT_METALLB=$(gum input --prompt "MetalLB IP Range: " --placeholder "${METALLB_IP_RANGE}")
export METALLB_IP_RANGE="${INPUT_METALLB:-${METALLB_IP_RANGE}}"

export CONTROL_PLANE_REPLICAS=$(gum choose --header "Number of Control Plane Nodes (Must be odd):" "1" "3" "5")

INPUT_WORKER=$(gum input --prompt "Number of Worker Nodes: " --placeholder "${WORKER_REPLICAS}")
export WORKER_REPLICAS="${INPUT_WORKER:-${WORKER_REPLICAS}}"

gum style --foreground 99 -- "--- Nutanix Prism Details ---"
INPUT_PC=$(gum input --prompt "Prism Central IP/FQDN (NO https://): " --placeholder "${PC_ENDPOINT}")
export PC_ENDPOINT="${INPUT_PC:-${PC_ENDPOINT}}"

INPUT_USER=$(gum input --prompt "Prism Central Username: " --placeholder "${NUTANIX_USER}")
export NUTANIX_USER="${INPUT_USER:-${NUTANIX_USER}}"

if [ -n "$NUTANIX_PASSWORD" ]; then
    INPUT_PASS=$(gum input --password --prompt "Prism Central Password [*** CACHED ***]: " --placeholder "Press Enter to keep cached password")
    export NUTANIX_PASSWORD="${INPUT_PASS:-${NUTANIX_PASSWORD}}"
else
    INPUT_PASS=$(gum input --password --prompt "Prism Central Password: " --placeholder "Type your password...")
    export NUTANIX_PASSWORD="${INPUT_PASS:-${NUTANIX_PASSWORD}}"
fi

INPUT_PE=$(gum input --prompt "Prism Element Cluster Name (Case-Sensitive): " --placeholder "${PE_CLUSTER}")
export PE_CLUSTER="${INPUT_PE:-${PE_CLUSTER}}"

INPUT_SUBNET_NAME=$(gum input --prompt "Subnet Name: " --placeholder "${SUBNET_NAME}")
export SUBNET_NAME="${INPUT_SUBNET_NAME:-${SUBNET_NAME}}"

INPUT_STORAGE=$(gum input --prompt "CSI Storage Container Name: " --placeholder "${STORAGE_CONTAINER}")
export STORAGE_CONTAINER="${INPUT_STORAGE:-${STORAGE_CONTAINER}}"

{
    echo "export CLUSTER_NAME=\"${CLUSTER_NAME}\""
    echo "export PC_ENDPOINT=\"${PC_ENDPOINT}\""
    echo "export NUTANIX_USER=\"${NUTANIX_USER}\""
    echo "export NUTANIX_PASSWORD=\"${NUTANIX_PASSWORD}\""
    echo "export PE_CLUSTER=\"${PE_CLUSTER}\""
    echo "export SUBNET_NAME=\"${SUBNET_NAME}\""
    echo "export STORAGE_CONTAINER=\"${STORAGE_CONTAINER}\""
    echo "export CONTROL_PLANE_VIP=\"${CP_VIP}\""
    echo "export METALLB_IP_RANGE=\"${METALLB_IP_RANGE}\""
    echo "export CONTROL_PLANE_REPLICAS=\"${CONTROL_PLANE_REPLICAS}\""
    echo "export WORKER_REPLICAS=\"${WORKER_REPLICAS}\""
} > "$CACHE_FILE"
chmod 600 "$CACHE_FILE"

# ==============================================================================
# STEP 2: PREPARATION & IMAGE PUSH
# ==============================================================================
gum style --foreground 212 -- "--- Ready to Deploy ---"
CONFIRM=$(gum choose --header "Proceed with cluster creation?" "Yes, Deploy Now" "No, Cancel")

if [ "$CONFIRM" == "No, Cancel" ]; then
    gum style --foreground 226 "Deployment cancelled by user."
    exit 0
fi

echo "export CLUSTER_NAME=\"${CLUSTER_NAME}\"" > .nkp_cluster.env

export NUTANIX_USER="${NUTANIX_USER}"
export NUTANIX_USERNAME="${NUTANIX_USER}"
export NUTANIX_PASSWORD="${NUTANIX_PASSWORD}"
export NUTANIX_ENDPOINT="${PC_ENDPOINT}"

echo "Cleaning up any stale Docker containers..."
nkp delete bootstrap --kubeconfig "$HOME/.kube/config" 2>/dev/null || true
docker rm -f nkp-bootstrap-control-plane 2>/dev/null || true

echo "------------------------------------------------------------------------------"
gum style --foreground 240 "Logging local Docker engine into Harbor..."
echo "${REGISTRY_PASS}" | docker login "${REGISTRY_URL}" -u "${REGISTRY_USER}" --password-stdin 2>/dev/null

gum style --foreground 240 "Provisioning dedicated 'nkp' project in Harbor..."
curl -s -k -u "${REGISTRY_USER}:${REGISTRY_PASS}" -X POST "https://${REGISTRY_URL}/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name": "nkp", "metadata": {"public": "true"}}' > /dev/null || true

gum style --foreground 212 "1/3: Pushing Konvoy Core Bundle to Harbor (${REGISTRY_URL}/nkp)..."
nkp push bundle --bundle "nkp-${NKP_VERSION}/container-images/konvoy-image-bundle-${NKP_VERSION}.tar" \
  --to-registry="${REGISTRY_URL}/nkp" \
  --to-registry-username="${REGISTRY_USER}" \
  --to-registry-password="${REGISTRY_PASS}" \
  --to-registry-ca-cert-file="${REGISTRY_CA}"

gum style --foreground 212 "2/3: Pushing Kommander App Bundle to Harbor (${REGISTRY_URL}/nkp)..."
nkp push bundle --bundle "nkp-${NKP_VERSION}/container-images/kommander-image-bundle-${NKP_VERSION}.tar" \
  --to-registry="${REGISTRY_URL}/nkp" \
  --to-registry-username="${REGISTRY_USER}" \
  --to-registry-password="${REGISTRY_PASS}" \
  --to-registry-ca-cert-file="${REGISTRY_CA}"

gum style --foreground 212 "3/3: Loading bootstrap image into local docker..."
docker load -i "nkp-${NKP_VERSION}/konvoy-bootstrap-image-${NKP_VERSION}.tar" > /dev/null
echo "------------------------------------------------------------------------------"

# ==============================================================================
# STEP 3: FULLY AUTOMATED CLUSTER DEPLOYMENT
# ==============================================================================
gum style --foreground 240 "Starting Native Cluster API Deployment (Streaming logs below)..."
echo "------------------------------------------------------------------------------"

if ! nkp create cluster nutanix --cluster-name="${CLUSTER_NAME}" \
  --control-plane-prism-element-cluster="${PE_CLUSTER}" --worker-prism-element-cluster="${PE_CLUSTER}" \
  --control-plane-subnet-names="${SUBNET_NAME}" --worker-subnet-names="${SUBNET_NAME}" \
  --control-plane-endpoint-ip="${CP_VIP}" \
  --control-plane-replicas="${CONTROL_PLANE_REPLICAS}" \
  --worker-replicas="${WORKER_REPLICAS}" \
  --csi-storage-container="${STORAGE_CONTAINER}" \
  --endpoint="https://${PC_ENDPOINT}:9440" \
  --control-plane-vm-image="${IMAGE_NAME}" \
  --worker-vm-image="${IMAGE_NAME}" \
  --kubernetes-service-load-balancer-ip-range="${METALLB_IP_RANGE}" \
  --registry-mirror-url="https://${REGISTRY_URL}/nkp" \
  --registry-mirror-username="${REGISTRY_USER}" \
  --registry-mirror-password="${REGISTRY_PASS}" \
  --registry-mirror-cacert="${REGISTRY_CA}" \
  --ssh-public-key-file="$HOME/.ssh/id_rsa.pub" \
  --airgapped --self-managed --insecure; then
    
    echo "------------------------------------------------------------------------------"
    gum style --foreground 196 "❌ ERROR: Cluster deployment failed! Check the logs above."
    exit 1
fi

echo "------------------------------------------------------------------------------"

# ==============================================================================
# STEP 4: VERIFICATION & HANDOFF
# ==============================================================================
gum style --foreground 240 "Verifying newly generated kubeconfig..."

if [ ! -s "${CLUSTER_NAME}.conf" ]; then
    gum style --foreground 196 "❌ ERROR: ${CLUSTER_NAME}.conf not found or empty! The deployment may not have finished correctly."
    exit 1
fi

if [ -n "${SUDO_USER:-}" ]; then
    chown "${SUDO_USER}:${SUDO_USER}" "${CLUSTER_NAME}.conf" || true
fi

gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "🎉 SUCCESS! The Kubernetes cluster '${CLUSTER_NAME}' has been fully provisioned and self-managed."

export KUBECONFIG="$PWD/${CLUSTER_NAME}.conf"

gum style --foreground 212 -- "--- Kommander Dashboard Details ---"
nkp get dashboard --kubeconfig="${KUBECONFIG}"
echo ""