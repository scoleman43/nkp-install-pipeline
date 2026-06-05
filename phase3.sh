#!/bin/bash
# ==============================================================================
# Script: 03_deploy_cluster.sh
# Purpose: Gathers cluster sizing/networking details via UI and uses native 
#          NKP automation to seamlessly deploy the air-gapped cluster.
# ==============================================================================

set -euo pipefail

# ==============================================================================
# STEP 0: LOAD PREVIOUS PHASE DATA
# ==============================================================================
gum style --foreground 212 -- "--- Checking Prerequisites ---"

if [ -f ".nkp_version.env" ] && [ -f ".nkp_image.env" ]; then
    source .nkp_version.env
    source .nkp_image.env
    export PATH="$PWD/nkp-${NKP_VERSION}/cli:$PATH"
    gum style --foreground 82 "✔ Found NKP Version: ${NKP_VERSION}"
    gum style --foreground 82 "✔ Found Target Image: ${IMAGE_NAME}"
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
export REGISTRY_IP=$(hostname -I | awk '{print $1}')
export REGISTRY_URL="${REGISTRY_IP}:5000" 
export REGISTRY_CA="/opt/registry/certs/domain.crt" 
export PC_ENDPOINT="192.168.43.43" 
export NUTANIX_USER="admin"
export NUTANIX_PASSWORD=""
export PE_CLUSTER="PE_Cluster_Name"
export SUBNET="VLAN_UUID_Goes_Here" 
export STORAGE_CONTAINER="Default_Container"
export CONTROL_PLANE_VIP="10.0.0.50"
export METALLB_IP_RANGE="10.0.0.100-10.0.0.150"
export CONTROL_PLANE_REPLICAS="3"
export WORKER_REPLICAS="3"

# ==============================================================================
# STEP 1: LOAD CACHE & INTERACTIVE CONFIGURATION
# ==============================================================================
CACHE_FILE=".nkp_phase3_cache.env"
if [ -f "$CACHE_FILE" ]; then
    gum style --foreground 240 "Loading previous configuration cache..."
    source "$CACHE_FILE"
fi

gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "NKP Phase 3: Nutanix Cluster Deployment"

gum style --foreground 99 -- "--- Cluster Identity & Sizing ---"
export CLUSTER_NAME=$(gum input --prompt "Cluster Name: " --value "${CLUSTER_NAME}")
export CP_VIP=$(gum input --prompt "Control Plane VIP (Unused IP): " --value "${CONTROL_PLANE_VIP}")
export METALLB_IP_RANGE=$(gum input --prompt "MetalLB IP Range: " --value "${METALLB_IP_RANGE}")
export CONTROL_PLANE_REPLICAS=$(gum choose --header "Number of Control Plane Nodes (Must be odd):" "1" "3" "5")
export WORKER_REPLICAS=$(gum input --prompt "Number of Worker Nodes: " --value "${WORKER_REPLICAS}")

gum style --foreground 99 -- "--- Nutanix Prism Details ---"
export PC_ENDPOINT=$(gum input --prompt "Prism Central IP/FQDN (NO https://): " --value "${PC_ENDPOINT}")
export NUTANIX_USER=$(gum input --prompt "Prism Central Username: " --value "${NUTANIX_USER}")

if [ -n "$NUTANIX_PASSWORD" ]; then
    export NUTANIX_PASSWORD=$(gum input --password --prompt "Prism Central Password [*** CACHED ***]: " --value "${NUTANIX_PASSWORD}")
else
    export NUTANIX_PASSWORD=$(gum input --password --prompt "Prism Central Password: " --placeholder "Type your password...")
fi

export PE_CLUSTER=$(gum input --prompt "Prism Element Cluster Name (Case-Sensitive): " --value "${PE_CLUSTER}")
export SUBNET=$(gum input --prompt "Subnet UUID: " --value "${SUBNET}")
export STORAGE_CONTAINER=$(gum input --prompt "CSI Storage Container Name: " --value "${STORAGE_CONTAINER}")

# Cache the answers for next time using bulletproof echo statements
{
    echo "export CLUSTER_NAME=\"${CLUSTER_NAME}\""
    echo "export PC_ENDPOINT=\"${PC_ENDPOINT}\""
    echo "export NUTANIX_USER=\"${NUTANIX_USER}\""
    echo "export NUTANIX_PASSWORD=\"${NUTANIX_PASSWORD}\""
    echo "export PE_CLUSTER=\"${PE_CLUSTER}\""
    echo "export SUBNET=\"${SUBNET}\""
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

# Export credentials for the NKP CLI to consume natively
export NUTANIX_USER="${NUTANIX_USER}"
export NUTANIX_USERNAME="${NUTANIX_USER}"
export NUTANIX_PASSWORD="${NUTANIX_PASSWORD}"
export NUTANIX_ENDPOINT="${PC_ENDPOINT}"

echo "Cleaning up any stale Docker containers..."
nkp delete bootstrap --kubeconfig "$HOME/.kube/config" 2>/dev/null || true
docker rm -f nkp-bootstrap-control-plane 2>/dev/null || true

gum spin --spinner line --title "Pushing NKP bundles to local registry (${REGISTRY_URL})..." -- bash -c "nkp push bundle --bundle \"nkp-${NKP_VERSION}/container-images/konvoy-image-bundle-${NKP_VERSION}.tar\" --to-registry=\"${REGISTRY_URL}\" --to-registry-ca-cert-file=\"${REGISTRY_CA}\" && nkp push bundle --bundle \"nkp-${NKP_VERSION}/container-images/kommander-image-bundle-${NKP_VERSION}.tar\" --to-registry=\"${REGISTRY_URL}\" --to-registry-ca-cert-file=\"${REGISTRY_CA}\""

gum spin --spinner line --title "Loading bootstrap image into local docker..." -- docker load -i "nkp-${NKP_VERSION}/konvoy-bootstrap-image-${NKP_VERSION}.tar" > /dev/null

# ==============================================================================
# STEP 3: FULLY AUTOMATED CLUSTER DEPLOYMENT
# ==============================================================================
gum style --foreground 240 "Starting Native Cluster API Deployment (Streaming logs below)..."
echo "------------------------------------------------------------------------------"

if ! nkp create cluster nutanix --cluster-name="${CLUSTER_NAME}" \
  --control-plane-prism-element-cluster="${PE_CLUSTER}" --worker-prism-element-cluster="${PE_CLUSTER}" \
  --control-plane-subnets="${SUBNET}" --worker-subnets="${SUBNET}" \
  --control-plane-endpoint-ip="${CP_VIP}" \
  --control-plane-replicas="${CONTROL_PLANE_REPLICAS}" \
  --worker-replicas="${WORKER_REPLICAS}" \
  --csi-storage-container="${STORAGE_CONTAINER}" \
  --endpoint="https://${PC_ENDPOINT}:9440" \
  --control-plane-vm-image="${IMAGE_NAME}" \
  --worker-vm-image="${IMAGE_NAME}" \
  --kubernetes-service-load-balancer-ip-range="${METALLB_IP_RANGE}" \
  --registry-mirror-url="https://${REGISTRY_URL}" \
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

echo "export CLUSTER_NAME=\"${CLUSTER_NAME}\"" > .nkp_cluster.env

gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "🎉 SUCCESS! The Kubernetes cluster '${CLUSTER_NAME}' has been fully provisioned and self-managed."

export KUBECONFIG="$PWD/${CLUSTER_NAME}.conf"
gum style --foreground 212 "Checking new cluster nodes:"
kubectl get nodes
echo ""
gum style --foreground 82 "You can now run Phase 4 to install the Management Plane & Harbor!"