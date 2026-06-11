#!/bin/bash
# ==============================================================================
# Script: phase1.sh
# Purpose: Prepares Bastion Host, configures Proxy OR Offline Bundle, automates 
#          'gum' UI, generates SSH keys, and installs Enterprise Harbor Registry.
# ==============================================================================

set -euo pipefail

# FIX: Force 256-color support for standalone 'gum' binary in PuTTY/Web Consoles
export TERM="xterm-256color"

export REGISTRY_PORT="5000"
export REGISTRY_CERTS_DIR="/opt/registry/certs"
export HARBOR_VERSION="v2.10.3"

# SC2155 Fix: Declare and assign separately
REGISTRY_IP=$(hostname -I | awk '{print $1}')
export REGISTRY_IP
export REGISTRY_URL="${REGISTRY_IP}:${REGISTRY_PORT}"

# shellcheck disable=SC1091
if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else echo "Unsupported OS."; exit 1; fi

echo "Please authenticate sudo so we can configure the system uninterrupted:"
sudo -v

# ==============================================================================
# STEP 0: INSTALLATION MODE (Standard Bash)
# ==============================================================================
if [ -z "${INSTALL_MODE:-}" ]; then
    echo "--- Select Bastion Installation Mode ---"
    echo "1) Internet-Based (Direct or via Corporate Proxy)"
    echo "2) Dark Site / Air-Gapped (Requires 'nkp-prereqs-bundle.tar.gz')"
    
    read -r -p "Select Mode (1 or 2): " MODE_SELECTION
    
    if [ "$MODE_SELECTION" == "2" ]; then
        export INSTALL_MODE="dark"
        export USE_PROXY="false"
        
        if [ ! -f "nkp-prereqs-bundle.tar.gz" ]; then
            echo "❌ ERROR: 'nkp-prereqs-bundle.tar.gz' not found in current directory."
            exit 1
        fi
        
        echo "Extracting offline prerequisites bundle..."
        tar -xzf nkp-prereqs-bundle.tar.gz
        
        echo "Installing offline binaries..."
        sudo cp nkp-prereqs-bundle/binaries/kubectl /usr/local/bin/kubectl
        sudo cp nkp-prereqs-bundle/binaries/gum /usr/local/bin/gum
        
        echo "Installing offline OS packages..."
        if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
            sudo dpkg -i nkp-prereqs-bundle/packages/*.deb || true
            sudo apt-get install -f -y || true 
        elif [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
            sudo rpm -Uvh --force --nodeps nkp-prereqs-bundle/packages/*.rpm
        fi

    elif [ "$MODE_SELECTION" == "1" ]; then
        export INSTALL_MODE="internet"
        
        echo "--- Checking Network / Proxy Requirements ---"
        if [ -z "${http_proxy:-}" ]; then
            read -r -p "Do you need to configure a proxy for outbound internet access? (y/N): " needs_proxy
            if [[ "$needs_proxy" =~ ^[Yy] ]]; then
                export USE_PROXY="true"
                read -r -p "Proxy URL (e.g., http://proxy.corp.local:3128): " PROXY_URL
                read -r -p "NO_PROXY list (default: 127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16): " NO_PROXY_INPUT
                export PROXY_URL="${PROXY_URL}"
                export NO_PROXY="${NO_PROXY_INPUT:-127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16}"
            else
                export USE_PROXY="false"
            fi
        else
            export USE_PROXY="true"
            export PROXY_URL="${http_proxy}"
            read -r -p "NO_PROXY list (default: 127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16): " NO_PROXY_INPUT
            export NO_PROXY="${NO_PROXY_INPUT:-127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16}"
        fi

        if [ "${USE_PROXY}" == "true" ]; then
            export http_proxy="${PROXY_URL}"; export https_proxy="${PROXY_URL}"; export no_proxy="${NO_PROXY}"
            export HTTP_PROXY="${PROXY_URL}"; export HTTPS_PROXY="${PROXY_URL}"; export NO_PROXY="${NO_PROXY}"
            if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
                echo "Acquire::http::Proxy \"${PROXY_URL}\";" | sudo tee /etc/apt/apt.conf.d/proxy.conf > /dev/null
                echo "Acquire::https::Proxy \"${PROXY_URL}\";" | sudo tee -a /etc/apt/apt.conf.d/proxy.conf > /dev/null
            elif [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
                grep -q "^proxy=" /etc/yum.conf || echo "proxy=${PROXY_URL}" | sudo tee -a /etc/yum.conf
            fi
        fi
        
        if ! command -v gum &> /dev/null; then
            echo "--- Preparing the Installer UI ---"
            if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
                sudo apt-get update -y -qq && sudo apt-get install -y -qq curl gnupg
                sudo mkdir -p /etc/apt/keyrings
                curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg
                echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
                sudo apt-get update -y -qq && sudo apt-get install -y -qq gum
            elif [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
                sudo yum install -y -q curl
                echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo > /dev/null
                sudo yum install -y -q gum
            fi
        fi
    else
        echo "Invalid selection."
        exit 1
    fi
    
    if command -v gum &> /dev/null; then
        echo "Dependencies installed successfully. Reloading script into UI mode..."
        sleep 1.5
        clear
        exec bash "$0" "$@"
    else
        echo "ERROR: Failed to initialize 'gum' UI."
        exit 1
    fi
fi

# ==============================================================================
# STEP 1: INTERACTIVE CONFIGURATION (Powered by Gum)
# ==============================================================================
gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "NKP Phase 1: Bastion Host & Harbor Registry Setup"

if [ "${INSTALL_MODE}" == "dark" ]; then
    export DOWNLOAD_BUNDLE="false"
    gum style --foreground 240 "Dark Site Mode Active: Skipping Internet Downloads."
else
    gum style --foreground 99 -- "--- Air-Gapped Bundle Configuration ---"
    DOWNLOAD_BUNDLE=$(gum choose --header "Do you want to automatically download the NKP air-gapped bundle?" "Yes" "No (I already uploaded it)")
fi

if [ "$DOWNLOAD_BUNDLE" == "Yes" ]; then
    export DOWNLOAD_BUNDLE="true"
    gum style --foreground 212 "Presigned URL:"
    read -r BUNDLE_URL
    export BUNDLE_URL="${BUNDLE_URL}"
    
    NKP_VERSION=$(echo "${BUNDLE_URL}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | head -n 1 || true)
    export NKP_VERSION
    
    if [ -z "$NKP_VERSION" ]; then
        NKP_VERSION=$(gum input --prompt "Version not found in URL. Enter NKP Version: " --value "v2.17.1")
        export NKP_VERSION
    fi
    export BUNDLE_ARCHIVE="nkp-air-gapped-bundle_${NKP_VERSION}_linux_amd64.tar.gz"
    gum style --foreground 82 "✔ Auto-detected Version: ${NKP_VERSION}"
else
    export DOWNLOAD_BUNDLE="false"
    
    BUNDLE_ARCHIVE=$(ls nkp-air-gapped-bundle_v*_linux_amd64.tar.gz 2>/dev/null | head -n 1 || true)
    export BUNDLE_ARCHIVE
    
    if [ -z "${BUNDLE_ARCHIVE}" ] || [ ! -f "${BUNDLE_ARCHIVE}" ]; then
        gum style --foreground 196 "❌ ERROR: Missing Nutanix NKP Software Bundle!"
        gum style --foreground 226 "Please download the official 'nkp-air-gapped-bundle_vX.X.X_linux_amd64.tar.gz' from the Nutanix Portal and place it in this directory alongside