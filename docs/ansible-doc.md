# Ansible Playbooks and Configurations

The `core-template` infrastructure is deployed via a sequential set of Ansible playbooks. The main entry point is `core/playbooks/core-config.yml`, which imports the individual playbook sections in order.

### Table of Contents
- [Playbook Breakdown](#playbook-breakdown)
- [Ansible Collections](#ansible-collections)
- [`ansible.cfg` Nuances](#ansiblecfg-nuances)
  - [1. Python Interpreter Pinning](#1-python-interpreter-pinning)
  - [2. Disabling Legacy Fact Injection](#2-disabling-legacy-fact-injection)
  - [3. Known Upstream Deprecation Warnings](#3-known-upstream-deprecation-warnings)

## Playbook Breakdown

| Playbook | Purpose |
|----------|---------|
| `00-controller-check.yml` | Validates the controller OS, installs APT dependencies, installs Docker Engine, and loads Docker images if running in offline mode. |
| `01-gen-vars-and-render-jinja.yml` | Idempotent generation of secrets, evaluates state/upgrade flags, and renders Jinja2 templates via Python. |
| `02-target-system-conditioning.yml` | Prepares the target host environment, configures UFW with a LAN allow-list. |
| `03-target-service-accounts.yml` | Creates localized system groups and service users (`nginx`, `bind`, `step`, `ldap`) on the target machine with specific UIDs/GIDs. |
| `04-target-file-structure.yml` | Replicates the directory tree onto the target (`/opt/...`), deploys the rendered configurations, systemd wrappers, and sets appropriate file ownership/permissions. |
| `05-target-network.yml` | Hardens `systemd-resolved` to prevent port 53 conflicts and performs additional network setup. |
| `06-configure-stepca.yml` | Initializes Step-CA, signs the intermediate CA CSR if deployed via BYOC, and establishes the foundational PKI structure. |
| `07-bootstrap-containers.yml` | Securely bootstraps foundational containers into existence. |
| `08-mint-service-certs.yml` | Uses the running Step-CA container to mint offline TLS certificates for BIND9, core services, and any `extra_certs`. |
| `09-start-and-configure.yml` | Starts the full stack via systemd wrappers, configures Keycloak, and handles LDAP mapping. |
| `10-deploy-checks-and-cleanup.yml` | Verifies DNS resolution, checks HTTPS health endpoints, exports startup logs, and cleans up temporary render directories. |

---

## Ansible Collections

The execution heavily relies on standard Ansible collections. These must be present on the controller machine (they are automatically packaged and installed by `offline.sh`).

1. **`community.docker`**
   - **Usage**: ~15+ tasks across the repository.
   - **Playbooks**: Heavily utilized in `00-system-check.yml`, `06-configure-stepca.yml`, `07-bootstrap-containers.yml`, `08-mint-service-certs.yml`, and `09-deploy-checks.yml`.
   - **Purpose**: Managing Docker containers (`docker_container`), Docker networks (`docker_network`), and full Compose stacks (`docker_compose_v2`).

2. **`community.general`**
   - **Usage**: ~8 tasks.
   - **Playbooks**: Utilized exclusively in `05-target-network.yml`.
   - **Purpose**: Manages the host firewall using the `ufw` module to ensure that ports are restricted appropriately based on the user's LAN CIDR configurations.

3. **`ansible.posix`**
   - **Usage**: Required implicitly for advanced Linux state management.
   - **Purpose**: Handling POSIX-specific operations (such as ACLs, SELinux booleans, or advanced file syncing). 

---

## `ansible.cfg` Nuances

The repository ships with its own `ansible.cfg` located in `core/playbooks/ansible.cfg`. It enforces several strict modernizations that developers modifying the playbooks must adhere to:

### 1. Python Interpreter Pinning
```ini
interpreter_python = /usr/bin/python3
```
- **Reason**: Suppresses Ansible's Python discovery warnings and ensures it always uses the system Python 3 on Ubuntu 24.04.

### 2. Disabling Legacy Fact Injection
```ini
inject_facts_as_vars = False
```
- **Reason**: Legacy behavior of injecting facts as top-level variables (e.g., `ansible_os_family`) was deprecated in Ansible 2.20 and removed in 2.24.
- **Requirement**: All playbooks in this repository MUST use the modern dictionary syntax to reference facts: `ansible_facts['os_family']`.

### 3. Known Upstream Deprecation Warnings
When running the installer, you may see a deprecation warning regarding `to_native` in `ansible.posix.acl`. 
- **Reason**: `ansible.posix.acl` version `2.1.0` imports from a deprecated path (`ansible.module_utils._text`).
- **Context**: This warning originates from the collection itself, not from the project's code. It cannot be suppressed per-module. It is harmless and will be resolved upstream when the collection is updated to `2.2.0` or higher.
