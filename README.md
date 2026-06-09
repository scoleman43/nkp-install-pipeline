# 🚀 NKP Install Pipeline (Air-Gapped Infrastructure Engine)

An end-to-end, highly resilient automation pipeline for deploying the **Nutanix Kubernetes Platform (NKP)** inside strictly air-gapped (Dark Site) computing environments.

**Crucial Architecture Note:** This pipeline is exclusively designed to provision air-gapped infrastructure. Whether the Bastion host operates completely offline (Dark Site Mode) or utilizes a transient internet connection to stream down binaries on-the-fly (Internet Mode), the target Nutanix environment, the node images, and the resulting Kubernetes cluster are **100% isolated and air-gapped**.

---

## ✨ Key Features

* **Strictly Air-Gapped Topology:** Regardless of the ingestion method, the final control plane and worker nodes rely entirely on local resources.
* **Automated Staging Bundling:** Uses GitHub Actions to compile a weekly offline prerequisites bundle (`docker`, `kubectl`, `gum`, `harbor`) to bypass local OS dependency conflicts.
* **Local Enterprise Harbor Registry:** Automatically deploys and configures a self-contained Harbor registry with auto-generated SSL certificates and an isolated `/nkp` project architecture.
* **Interactive Terminal UI:** Built with `charmbracelet/gum` for a beautiful, error-resistant, menu-driven installation experience (with full 256-color support).
* **Smart Credential Caching:** Caches Nutanix Prism Central credentials and network details between runs to survive network timeouts without forcing manual re-entry.
* **Self-Managed Magic:** Combines Cluster API (Phase 3) and Kommander Management Plane installations into a single, seamless execution using the `--self-managed` architecture to bypass GitOps TLS proxy limitations.

---

## 🏗 Architecture Overview

The pipeline breaks the NKP installation down into a streamlined, sequential workflow:

1.  **Step 0: Prerequisites Builder (GitHub Actions)**
    Runs on GitHub's `ubuntu-latest` cloud runners to download offline binaries and safe OS packages, compiling them into `nkp-prereqs-bundle.tar.gz`. *(Only required if transferring data via physical media).*
2.  **Phase 1: Bastion & Harbor Registry (`phase1.sh`)**
    Extracts the prerequisites bundle (or downloads dependencies directly if the Bastion has temporary outbound access) on your target Bastion host, configures local Docker runtimes, generates SSL keys, and spins up your isolated local Harbor registry.
3.  **Phase 2: OS Image Staging (`phase2.sh`)**
    Connects to Nutanix Prism Central to stage the base QCOW2 image for the Kubernetes nodes. Supports selecting native Pre-Built NKP images uploaded to your environment (recommended for strict dark sites).
4.  **Phase 3: Cluster Deployment (`phase3.sh`)**
    Pushes 12GB+ of Nutanix container images from the Bastion directly into the local Harbor `/nkp` project, bootstraps the isolated cluster via CAPI, pivots the management plane, and automatically outputs secure Kommander UI dashboard credentials.

---

## 📋 Prerequisites

Before running the pipeline, ensure your core infrastructure meets these requirements:

1.  **Bastion Host:** A clean Ubuntu Linux VM (e.g., Ubuntu 22.04 or 26.04 LTS) with SSH access.
2.  **Nutanix Infrastructure Constraints:**
    * **Prism Central Sizing:** Prism Central **must** be deployed as size **Small** or larger. **Extra Small (X-Small) is strictly unsupported** and will cause API deployment timeouts during the automated air-gapped CAPI orchestrations.
    * Prism Central IP and Admin Credentials.
    * Target Prism Element Cluster Name.
    * Target Subnet/VLAN Name.
    * 1x VIP (Virtual IP) for the isolated Kubernetes Control Plane.
    * A dedicated block of unused IPs for local application load-balancing (MetalLB).

---

## 🚀 Quick Start Guide

### 1. Stage the Bastion
Transfer the three installation scripts (`phase1.sh`, `phase2.sh`, `phase3.sh`) to the home directory of your Bastion host and make them executable (`chmod +x phase*.sh`).

* **For True Dark Site Installs (Physical Media Transfer):** You must manually transfer both `.tar.gz` bundles into the same directory before starting.
  ```bash
  # Your Dark Site directory should look like this:
  ls -l
  # -rwxr-xr-x phase1.sh
  # -rwxr-xr-x phase2.sh
  # -rwxr-xr-x phase3.sh
  # -rw-r--r-- nkp-air-gapped-bundle_v2.17.1_linux_amd64.tar.gz
  # -rw-r--r-- nkp-prereqs-bundle.tar.gz
