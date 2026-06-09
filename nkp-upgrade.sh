#!/bin/bash
# ==============================================================================
# Script: nkp-upgrade.sh
# Purpose: Orchestrates a zero-downtime air-gapped upgrade of an existing 
#          NKP cluster to a new release version, with support for automatic downloads.
# ==============================================================================

set -euo pipefail

# Force 256-color support for 'gum' menus
export TERM="xterm-256color"

gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "NKP Day 2: Air-Gapped Cluster Upgrade"

# ==============================================================================
# STEP 0: ENVIRONMENT VALIDATION
# ==============================================================================
gum style --foreground 212 -- "--- Validating Existing Environment ---"

if [ -f ".nkp_registry.env" ]; then
    source .nkp_registry.env
    gum style --foreground 82 "✔ Found Harbor Registry: ${REGISTRY_URL}"
else
    gum style --foreground 196 "❌ ERROR: .nkp_registry.env not found. Ensure you are running this from your Bastion staging directory."
    exit 1
fi

if [ -f ".nkp_cluster.env" ]; then
    source .nkp_cluster.env
    gum style --foreground 82 "✔ Found Target Cluster: ${CLUSTER_NAME}"
else
    export CLUSTER_NAME=$(gum input --prompt "Enter your existing Cluster Name: " --placeholder "nkp-prod-01")
fi

export KUBECONFIG="$PWD/${CLUSTER_NAME}.conf"
if [ ! -f "${KUBECONFIG}" ]; then
    gum style --foreground 196 "❌ ERROR: Kubeconfig not found at ${KUBECONFIG}. Please ensure the config file is in this directory."
    exit 1
fi

# ==============================================================================
# STEP 1: NEW VERSION STAGING & DOWNLOAD
# ==============================================================================
gum style --foreground 99 -- "--- New Upgrade Bundle Configuration ---"

DOWNLOAD_CHOICE=$(gum choose --header "How do you want to provide the NEW NKP Upgrade Bundle?" "Use Local Air-Gapped Tarball (Dark Site)" "Download via Presigned URL (Internet Connected)")

if [ "$DOWNLOAD_CHOICE" == "Download via Presigned URL (Internet Connected)" ]; then
    gum style --foreground 212 "Presigned URL for the NEW version:"
    read -r NEW_BUNDLE_URL
    
    NEW_NKP_VERSION=$(echo "${NEW_BUNDLE_URL}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | head -n 1 || true)
    
    if [ -z "$NEW_NKP_VERSION" ]; then
        export NEW_NKP_VERSION=$(gum input --prompt "Version not found in URL. Enter NEW NKP Version (e.g. v2.x.x): " --placeholder "v2.18.0")
    fi
    
    export BUNDLE_ARCHIVE="nkp-air-gapped-bundle_${NEW_NKP_VERSION}_linux_amd64.tar.gz"
    gum style --foreground 82 "✔ Target Upgrade Version: ${NEW_NKP_VERSION}"
    
    gum style --foreground 212 "Downloading NKP Air-Gapped Bundle (~12GB). This may take a while..."
    if ! wget --show-progress -O "${BUNDLE_ARCHIVE}" "${NEW_BUNDLE_URL}"; then
        echo ""
        gum style --foreground 196 "❌ ERROR: Download failed! Check the wget output above to see why."
        exit 1
    fi
    gum style --foreground 82 "✔ Successfully downloaded ${BUNDLE_ARCHIVE}."

else
    BUNDLE_ARCHIVE=$(ls nkp-air-gapped-bundle_v*_linux_amd64.tar.gz 2>/dev/null | sort -V | tail -n 1 || true)
    
    if [ -z "${BUNDLE_ARCHIVE}" ]; then
        export BUNDLE_ARCHIVE=$(gum input --prompt "Enter the NEW bundle filename: " --placeholder "nkp-air-gapped-bundle_vX.X.X_linux_amd64.tar.gz")
    else
        gum style --foreground 82 "✔ Detected latest local bundle: ${BUNDLE_ARCHIVE}"
    fi

    if [ ! -f "${BUNDLE_ARCHIVE}" ]; then
        gum style --foreground 196 "❌ ERROR: ${BUNDLE_ARCHIVE} not found! Please transfer the new upgrade bundle to this directory."
        exit 1
    fi

    NEW_NKP_VERSION=$(echo "${BUNDLE_ARCHIVE}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | head -n 1 || true)
    
    if [ -z "$NEW_NKP_VERSION" ]; then
        export NEW_NKP_VERSION=$(gum input --prompt "Version not found in filename. Enter NEW NKP Version: " --placeholder "v2.x.x")
    else
        gum style --foreground 82 "✔ Target Upgrade Version: ${NEW_NKP_VERSION}"
    fi
fi

# ==============================================================================
# STEP 2: EXTRACTION & HARBOR PUSH
# ==============================================================================
gum style --foreground 212 -- "--- Ready to Upgrade ---"
CONFIRM=$(gum choose --header "Proceed with upgrading ${CLUSTER_NAME} to ${NEW_NKP_VERSION}?" "Yes, Upgrade Now" "No, Cancel")

if [ "$CONFIRM" == "No, Cancel" ]; then
    gum style --foreground 226 "Upgrade cancelled by user."
    exit 0
fi

if [ ! -d "nkp-${NEW_NKP_VERSION}" ]; then
    gum style --foreground 240 "Extracting new NKP bundle (This may take a few minutes)..."
    tar -xzf "${BUNDLE_ARCHIVE}"
fi

export PATH="$PWD/nkp-${NEW_NKP_VERSION}/cli:$PATH"

echo "------------------------------------------------------------------------------"
gum style --foreground 240 "Logging local Docker engine into Harbor..."
echo "${REGISTRY_PASS}" | docker login "${REGISTRY_URL}" -u "${REGISTRY_USER}" --password-stdin

gum style --foreground 212 "1/2: Pushing NEW Konvoy Core Bundle to Harbor (${REGISTRY_URL}/nkp)..."
nkp push bundle --bundle "nkp-${NEW_NKP_VERSION}/container-images/konvoy-image-bundle-${NEW_NKP_VERSION}.tar" \
  --to-registry="${REGISTRY_URL}/nkp" \
  --to-registry-username="${REGISTRY_USER}" \
  --to-registry-password="${REGISTRY_PASS}" \
  --to-registry-ca-cert-file="${REGISTRY_CA}"

gum style --foreground 212 "2/2: Pushing NEW Kommander App Bundle to Harbor (${REGISTRY_URL}/nkp)..."
nkp push bundle --bundle "nkp-${NEW_NKP_VERSION}/container-images/kommander-image-bundle-${NEW_NKP_VERSION}.tar" \
  --to-registry="${REGISTRY_URL}/nkp" \
  --to-registry-username="${REGISTRY_USER}" \
  --to-registry-password="${REGISTRY_PASS}" \
  --to-registry-ca-cert-file="${REGISTRY_CA}"
echo "------------------------------------------------------------------------------"

# ==============================================================================
# STEP 3: CLUSTER UPGRADE
# ==============================================================================
gum style --foreground 240 "Starting Native Cluster API Upgrade (Streaming logs below)..."
echo "------------------------------------------------------------------------------"

if ! nkp upgrade cluster --kubeconfig="${KUBECONFIG}"; then
    echo "------------------------------------------------------------------------------"
    gum style --foreground 196 "❌ ERROR: Cluster upgrade failed! Check the logs above."
    exit 1
fi

echo "------------------------------------------------------------------------------"
gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "🎉 SUCCESS! ${CLUSTER_NAME} has been successfully upgraded to ${NEW_NKP_VERSION}."

# Update the version tracker for future reference
echo "export NKP_VERSION=\"${NEW_NKP_VERSION}\"" > .nkp_version.env
echo "export BUNDLE_ARCHIVE=\"${BUNDLE_ARCHIVE}\"" >> .nkp_version.env