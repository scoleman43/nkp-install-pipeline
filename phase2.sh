#!/bin/bash
# ==============================================================================
# Script: phase2.sh
# Purpose: Interactively gather infrastructure details, build a custom 
#          Nutanix OS image using NKP 2.17+ syntax, or use a pre-built one.
# ==============================================================================

set -euo pipefail

# FIX 1: Ensure 256-color support for 'gum' menus
export TERM="xterm-256color"

# FIX 2: Load both Version and Registry environment files
if [ -f ".nkp_version.env" ] && [ -f ".nkp_registry.env" ]; then
    source .nkp_version.env
    source .nkp_registry.env
else
    gum style --foreground 196 "❌ ERROR: Environment files (.nkp_version.env / .nkp_registry.env) not found. Please run Phase 1 first."
    exit 1
fi

export PATH="$PWD/nkp-${NKP_VERSION}/cli:$PATH"

# Setup local cache file for resilient retries
CACHE_FILE=".nkp_phase2_cache.env"
if [ -f "$CACHE_FILE" ]; then
    source "$CACHE_FILE"
fi

# ==============================================================================
# STEP 1: INTERACTIVE CONFIGURATION
# ==============================================================================
clear
gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "NKP Phase 2: Node OS Image Setup (${NKP_VERSION})"

if [ ! -d "nkp-${NKP_VERSION}" ]; then
    gum style --foreground 196 "❌ ERROR: nkp-${NKP_VERSION} directory not found. Please run Phase 1 first."
    exit 1
fi

BUILD_CHOICE=$(gum choose --header "How do you want to handle the Node OS Image?" "Use a Pre-Built Image (Best for Dark Sites)" "Build a Custom NKP Image (Requires Internet or Local Mirrors)")

if [ "$BUILD_CHOICE" == "Build a Custom NKP Image (Requires Internet or Local Mirrors)" ]; then
    export USE_CUSTOM_IMAGE="true"
    
    gum style --foreground 99 -- "--- Custom Image Configuration ---"
    
    # 🚨 DARK SITE WARNING 🚨
    gum style --border normal --margin "1" --padding "1 2" --border-foreground 226 "⚠️ AIR-GAP WARNING: Building a custom image requires the temporary builder VM to download OS packages. If this is a Dark Site, your Base Image MUST be configured to use an internal APT/YUM mirror, or this build will timeout."
    
    CONFIRM_BUILD=$(gum choose --header "Do you want to proceed with the custom build?" "Yes, my network/mirrors are ready" "No, let me use a Pre-Built Image instead")
    
    if [ "$CONFIRM_BUILD" == "No, let me use a Pre-Built Image instead" ]; then
        export USE_CUSTOM_IMAGE="false"
        gum style --foreground 99 -- "--- Default Image Configuration ---"
        export IMAGE_NAME=$(gum input --prompt "Pre-built Image Name in PC: " --placeholder "nkp-ubuntu-22.04-12345")
    else
        # FIX 3: Implementing credential caching
        export OS_NAME=$(gum choose --header "Target OS Name:" "ubuntu-22.04" "rocky-9.6" "rhel-8.10")
        
        INPUT_PC=$(gum input --prompt "Prism Central IP/FQDN (NO https://): " --placeholder "${PC_ENDPOINT:-10.x.x.x}")
        export PC_ENDPOINT="${INPUT_PC:-${PC_ENDPOINT:-}}"
        
        INPUT_USER=$(gum input --prompt "Prism Central Username: " --placeholder "${NUTANIX_USER:-admin}")
        export NUTANIX_USER="${INPUT_USER:-${NUTANIX_USER:-admin}}"
        
        if [ -n "${NUTANIX_PASSWORD:-}" ]; then
            INPUT_PASS=$(gum input --password --prompt "Prism Central Password [*** CACHED ***]: " --placeholder "Press Enter to keep cached password")
            export NUTANIX_PASSWORD="${INPUT_PASS:-${NUTANIX_PASSWORD}}"
        else
            INPUT_PASS=$(gum input --password --prompt "Prism Central Password: " --placeholder "Type your password...")
            export NUTANIX_PASSWORD="${INPUT_PASS}"
        fi
        
        INPUT_PE=$(gum input --prompt "Prism Element Cluster Name: " --placeholder "${PE_CLUSTER:-PE_Cluster_Name}")
        export PE_CLUSTER="${INPUT_PE:-${PE_CLUSTER:-}}"
        
        INPUT_SUBNET_NAME=$(gum input --prompt "Subnet Name: " --placeholder "${SUBNET_NAME:-Default-Network}")
        export SUBNET_NAME="${INPUT_SUBNET_NAME:-${SUBNET_NAME:-}}"
        
        INPUT_BASE=$(gum input --prompt "Base Image Name in PC: " --placeholder "${BASE_IMAGE_VAL:-Ubuntu_22.04_Base}")
        export BASE_IMAGE_VAL="${INPUT_BASE:-${BASE_IMAGE_VAL:-}}"
        
        # Save cache for next run
        {
            echo "export PC_ENDPOINT=\"${PC_ENDPOINT}\""
            echo "export NUTANIX_USER=\"${NUTANIX_USER}\""
            echo "export NUTANIX_PASSWORD=\"${NUTANIX_PASSWORD}\""
            echo "export PE_CLUSTER=\"${PE_CLUSTER}\""
            echo "export SUBNET_NAME=\"${SUBNET_NAME}\""
            echo "export BASE_IMAGE_VAL=\"${BASE_IMAGE_VAL}\""
        } > "$CACHE_FILE"
        chmod 600 "$CACHE_FILE"
    fi

else
    export USE_CUSTOM_IMAGE="false"
    gum style --foreground 99 -- "--- Default Image Configuration ---"
    export IMAGE_NAME=$(gum input --prompt "Pre-built Image Name in PC: " --placeholder "nkp-ubuntu-22.04-12345")
fi

# ==============================================================================
# STEP 2: IMAGE CREATION & EXTRACTION
# ==============================================================================
gum style --foreground 212 -- "--- Beginning Image Setup ---"

if [ "${USE_CUSTOM_IMAGE}" == "true" ]; then
    gum style --foreground 240 "Streaming Packer logs for custom image build (This takes 10-15 mins)..."
    echo "------------------------------------------------------------------------------"
    
    export NUTANIX_USER="${NUTANIX_USER}"
    export NUTANIX_USERNAME="${NUTANIX_USER}" 
    export NUTANIX_PASSWORD="${NUTANIX_PASSWORD}"
    export NUTANIX_ENDPOINT="${PC_ENDPOINT}"
    
    if ! nkp create image nutanix "${OS_NAME}" \
      --endpoint="${PC_ENDPOINT}" \
      --cluster="${PE_CLUSTER}" \
      --subnet="${SUBNET_NAME}" \
      --source-image="${BASE_IMAGE_VAL}" \
      --insecure; then
        
        echo "------------------------------------------------------------------------------"
        gum style --foreground 196 "❌ ERROR: Image build failed! Please look at the logs above to see the exact API or configuration error."
        exit 1
    fi
    echo "------------------------------------------------------------------------------"

    gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "SUCCESS! Your custom image was built."
    
    gum style --foreground 212 "Please look at the end of the logs above for the final image name (e.g., nkp-ubuntu-22.04-xxx)."
    export EXTRACTED_IMAGE=$(gum input --prompt "Paste the new image name here: " --placeholder "nkp-ubuntu-22.04-...")
    echo "export IMAGE_NAME=\"${EXTRACTED_IMAGE}\"" > .nkp_image.env
    
else
    echo "export IMAGE_NAME=\"${IMAGE_NAME}\"" > .nkp_image.env
    gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "READY: Using Pre-Built Image: ${IMAGE_NAME}"
fi