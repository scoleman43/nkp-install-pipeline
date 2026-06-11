# 🚀 NKP Install Pipeline (Air-Gapped Infrastructure Engine)

An end-to-end, highly resilient automation pipeline for deploying and managing the **Nutanix Kubernetes Platform (NKP)** inside strictly air-gapped (Dark Site) computing environments.

> **⚠️ CRUCIAL ARCHITECTURE NOTE** > This pipeline is exclusively designed to provision air-gapped infrastructure. Whether the Bastion host operates completely offline (*Dark Site Mode*) or utilizes a transient internet connection to stream down binaries on-the-fly (*Internet Mode*), the target Nutanix environment, the node images, and the resulting Kubernetes cluster are **100% isolated and air-gapped**.

---

## ✨ Key Features

* **Strictly Air-Gapped Topology:** Regardless of the ingestion method, the final control plane and worker nodes rely entirely on local resources.
* **Automated Staging Bundling:** Uses GitHub Actions to compile a weekly offline prerequisites bundle (`docker`, `kubectl`, `gum`, `harbor`) to bypass local OS dependency conflicts.
* **Local Enterprise Harbor Registry:** Automatically deploys and configures a self-contained Harbor registry with auto-generated SSL certificates and an isolated `/nkp` project architecture.
* **Interactive Terminal UI:** Built with `charmbracelet/gum` for a beautiful, error-resistant, menu-driven installation experience (with full 256-color support).
* **Smart Credential Caching:** Caches Nutanix Prism Central credentials and network details between runs to survive network timeouts without forcing manual re-entry.
* **Day 2 Operations Support:** Includes native upgrade scripts to seamlessly orchestrate zero-downtime cluster upgrades when new versions of NKP are released.

---

## 🏗 Architecture Overview

The pipeline breaks the NKP lifecycle down into a streamlined, sequential workflow:

| Phase | Script | Purpose |
| :--- | :--- | :--- |
| **0** | `GitHub Actions` | **Prerequisites Builder:** Runs on cloud runners to download offline binaries and safe OS packages, compiling them into a `tar.gz`which can be downloaded from the Releases section. *(Only required for physical media transfers).* |
| **1** | `phase1.sh` | **Bastion & Harbor Registry:** Configures local Docker runtimes, generates SSL keys, and spins up your isolated local Harbor registry. |
| **2** | `phase2.sh` | **OS Image Staging:** Connects to Nutanix Prism Central to stage the base QCOW2 image for the Kubernetes nodes. |
| **3** | `phase3.sh` | **Cluster Deployment:** Pushes 12GB+ of Nutanix container images into Harbor, bootstraps the isolated cluster via CAPI, and outputs UI dashboard credentials. |
| **Day 2** | `nkp-upgrade.sh` | **Cluster Upgrades:** Stablishes a clean path for pushing updated container bundles into Harbor and orchestrating a rolling cluster upgrade. |

---

## 📋 Prerequisites

Before running the pipeline, ensure your core infrastructure meets these requirements:

### 1. Bastion Host
* A clean Ubuntu Linux VM (e.g., **Ubuntu 22.04 LTS** or **26.04 LTS**).
* Active SSH access.

### 2. Nutanix Infrastructure Constraints
* **Prism Central Sizing:** Prism Central **MUST** be deployed as size **Small** or larger. 
  > 🛑 *Extra Small (X-Small) is strictly unsupported and will cause API deployment timeouts during the automated air-gapped CAPI orchestrations.*
* Prism Central IP and Admin Credentials.
* Target Prism Element Cluster Name.
* Target Subnet/VLAN Name.
* **1x VIP** (Virtual IP) for the isolated Kubernetes Control Plane.
* A dedicated block of unused IPs for local application load-balancing (MetalLB).

---

## 🚀 Quick Start Guide: Initial Deployment

To execute the air-gapped installation script, you will first need to provision a Linux bastion VM within your Nutanix environment. We recommend using Ubuntu Server for this host. 

### VM Specifications
Ensure your bastion VM meets the following minimum requirements:
* **vCPUs:** 2
* **Memory (RAM):** 12 GB
* **Storage:** 100 GB minimum *(Note: When creating the disk from the source image, you must explicitly expand the size from 3.5GB to at least 100GB. I would set it to 200GB if you intended to deploy NAI air-gapped to accommodate the NAI bundles and container images).*

### Source Image
You can use the official Ubuntu Resolute cloud image. Download or provide the following URL to your cluster:
> `https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img`

### Cloud-Init Configuration
To ensure you have immediate access to the VM, use the following `cloud-init` script during the VM creation process. This will configure the default `ubuntu` user with a set password, disable password expiration, and enable SSH password authentication.

**Custom Script (Cloud-Config):**
```yaml
#cloud-config
password: password1
chpasswd: { expire: False }
ssh_pwauth: True
```
### Step 1: Stage the Bastion
Transfer the installation scripts to the home directory of your Bastion host and make them executable:

```bash
chmod +x phase1.sh phase2.sh phase3.sh nkp-upgrade.sh
```

**For True Dark Site Installs (Physical Media Transfer):**
You must manually transfer both `.tar.gz` bundles into the same directory before starting. Your directory structure should look exactly like this:
```text
├── phase1.sh
├── phase2.sh
├── phase3.sh
├── nkp-upgrade.sh
├── nkp-air-gapped-bundle_v2.17.1_linux_amd64.tar.gz
└── nkp-prereqs-bundle.tar.gz
```
The ```nkp-air-gapped-bundle_v2.17.1_linux_amd64.tar.gz``` can be downloaded from the Nutanix support portal.
The ```nkp-prereqs-bundle.tar.gz``` can be downloaded from the GitHub Releases section on the main nkp-install-pipeline page.  

**For Internet-Assisted Bastion Installs:**
You only need the scripts. The pipeline will automatically prompt you for a presigned Nutanix URL and leverage the Bastion's temporary connection to pull down the required installation bundles into the local staging environment.

### Step 2: Run Phase 1 (Bastion & Registry Setup)
```bash
./phase1.sh
```
1. Select **Dark Site** or **Internet-Based** ingestion mode.
2. Follow the UI prompts to set your Harbor administrator password.
3. **IMPORTANT:** Once complete, type `exit` to close your SSH session, then log back in to ensure your user is successfully added to the `docker` security group.

### Step 3: Run Phase 2 (Image Staging)
```bash
./phase2.sh
```
1. Select **Use a Pre-Built Image** *(Highly recommended for air-gapped topologies to bypass the need for temporary builder VMs or local OS mirrors)*.
2. Enter the exact, case-sensitive name of the NKP QCOW2 image as it appears in your Prism Central Image Configuration UI.
3. You also have the option to build a **Custom Image** which will automate preparing and creating the OS of your choice as a image option in PC. 

### Step 4: Run Phase 3 (Cluster Deployment)
```bash
./phase3.sh
```
1. Enter your target Nutanix sizing, IP schemes, and Prism Central details.
2. Confirm deployment. The script will dynamically read your cached parameters and securely authenticate your local Docker engine against Harbor.
3. **Grab your Credentials:** Upon clean validation of the newly generated cluster config file, the script will print the active cluster URL, management username, and secure password to access your local Kommander dashboard.

---

## 🔄 Day 2 Operations: Upgrading NKP

When a new version of Nutanix Kubernetes Platform is released, upgrading your air-gapped cluster is fully automated via the `nkp-upgrade.sh` script.

### Step 1: Stage the New Bundle
Either transfer the new `.tar.gz` bundle to your Bastion directory manually, or have a presigned Nutanix URL ready.

### Step 2: Execute the Upgrade
```bash
./nkp-upgrade.sh
```
1. The script will validate your existing `kubeconfig` and Harbor credentials.
2. It will ask if you are utilizing a local tarball or a presigned download URL.
3. The new 12GB bundle will be unpacked, the local Harbor `/nkp` project will ingest the updated core container blueprints, and the CAPI upgrade sequence will be initiated against your cluster automatically.

---

## 🛠 Troubleshooting & Detailed Technical Notes

### 🔒 Harbor 401 Unauthorized Errors
* **Symptom:** The image stream immediately errors out with `unexpected status code 401 Unauthorized` during the initial push steps.
* **Root Cause:** Enterprise Harbor registries bar anonymous pushes to the root directory. If an image path is directed to the bare registry destination (`192.168.43.79:5000/calico/apiserver`), the infrastructure drops the connection.
* **Resolution:** The pipeline handles this natively by utilizing a `curl` pre-check loop to force create a dedicated `/nkp` directory structure via the Harbor API, ensuring all container payloads explicitly route inside a valid project namespace.

### 💥 Dangerous OS Dependency Crashes
* **Symptom:** The script crashes during certificate validation with `Segmentation fault (core dumped)` and completely breaks other binary tools on the Bastion.
* **Root Cause:** Core system automation tools (`openssl`, `tar`, `curl`) are tightly coupled to the host OS C-libraries (`glibc`). Blindly installing upstream `.deb` packages across modern architectures (like Ubuntu 26.04 LTS) overwrites system cryptography files, fracturing OS stability.
* **Resolution:** The automated Step 0 GitHub Actions workflow has been specifically designed to exclude core system packages from the ingestion loop. It exclusively fetches infrastructure runtimes (`docker-ce`, `containerd.io`). This protects your Bastion's OS integrity by allowing your host's native `openssl` binary to safely generate certificates uninterrupted.
