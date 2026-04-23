# Core Library Scripts Documentation

The `core/lib/` directory contains modular Bash scripts sourced by the main executables (`setup.sh`, `manage.sh`, `upgrade.sh`, `offline.sh`). These scripts provide specific functional domains to keep the entry point scripts clean.

> **Note**: These files are designed to be sourced (e.g., `source core/lib/output.sh`) and should not be executed directly.

### Table of Contents
- [1. `archive.sh`](#1-archivesh)
- [2. `certs.sh`](#2-certssh)
- [3. `dns.sh`](#3-dnssh)
- [4. `output.sh`](#4-outputsh)
- [5. `package.sh`](#5-packagesh)
- [6. `prereqs.sh`](#6-prereqssh)
- [7. `services.sh`](#7-servicessh)
- [8. `ssh.sh`](#8-sshsh)
- [9. `tsig.sh`](#9-tsigsh)
- [10. `upgrade.sh`](#10-upgradesh)
- [11. `vars.sh`](#11-varssh)

### 1. `archive.sh`
**Purpose**: Backup and snapshot utilities.
- Provides the `archive_snapshot()` function which creates a point-in-time snapshot of the current `/opt/core/` installation before applying structural updates or configuration changes. 
- It uses timestamps to keep multiple isolated snapshots in `core/archive/`.

### 2. `certs.sh`
**Purpose**: Certificate minting and management workflows.
- Contains the core logic for the `--mint-certs` and `--service-cert` operations.
- Interacts directly with the running `step-ca` container to issue new leaf certificates or subordinate CAs (`_mint_extra_cert()`).
- Bundles intermediate CA logic and formats output correctly for BIND9/NGINX.

### 3. `dns.sh`
**Purpose**: DNS record management workflows.
- Contains the logic for the `--dns-record` and `--remove-dns-record` operations (`do_dns_record()`).
- Interfaces with the `vars.yaml` file to append or remove DNS configurations interactively.
- Reloads the running BIND9 instance to apply changes seamlessly.

### 4. `output.sh`
**Purpose**: Formatting and logging.
- Defines standard, colorized output functions: `info()`, `ok()`, `warn()`, `err()`.
- Standardizes the console output aesthetics across all wrapper scripts to ensure a consistent user experience.

### 5. `package.sh`
**Purpose**: Offline prerequisite staging and installation.
- Orchestrates the `offline.sh` operations.
- Defines the canonical arrays for `CONTROLLER_APT_PACKAGES`, `ANSIBLE_COLLECTIONS`, `TARGET_APT_PACKAGES`, and `DOCKER_IMAGES`.
- Contains `do_package()` which downloads and packages these dependencies into `.tar` or `.zip` bundles for air-gapped deployments.

### 6. `prereqs.sh`
**Purpose**: Prerequisite extraction and loading.
- Used by `setup.sh` to handle the `--prereqs` and `--prereqs-target` arguments.
- Contains `_resolve_prereqs_dir()` which detects if the provided bundle is a zip/tar archive, unpacks it to a temporary directory, and registers a cleanup trap.

### 7. `services.sh`
**Purpose**: Direct execution runner for live systems.
- Replaces legacy Ansible-based live reloads with faster, direct shell/docker commands.
- Contains functions like `run_dns_reload()` which immediately applies configurations to live containers (e.g., executing `rndc reload` inside the BIND9 container).

### 8. `ssh.sh`
**Purpose**: SSH key distribution and trust management.
- Contains `ensure_ssh_access()` which automatically prepares SSH access to a remote host.
- Prompts for a user, generates a local Ed25519 keypair if needed, adds the remote host to `known_hosts`, and copies the public key using `ssh-copy-id`.

### 9. `tsig.sh`
**Purpose**: BIND9 TSIG key management workflows.
- Contains the logic for `--tsig-keys`, `--list-tsig`, and `--remove-tsig` (`do_tsig_keys()`).
- Manages the cryptographic keys used to authorize dynamic DNS updates.

### 10. `upgrade.sh`
**Purpose**: In-place feature upgrade orchestrator.
- Serves as the library backbone for the `upgrade.sh` executable wrapper.
- Contains `do_upgrade()` which extracts existing variables, coordinates the image pulls, drops the container stack, and triggers the Ansible upgrade playbook to merge state.

### 11. `vars.sh`
**Purpose**: YAML mutation helpers.
- Contains python-based inline parsers (e.g., `_vars_list_append()`) to dynamically mutate `custom-vars.yaml` and `vars.yaml` without breaking formatting.
- Tries to use `ruamel.yaml` to preserve user comments when appending new items (like DNS records or certificates) and falls back to `PyYAML` if necessary.
