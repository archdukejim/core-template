# AI Test Plan: Core Template Deployment

This document outlines the testing strategy for an AI agent to execute, validate, and troubleshoot the deployment of the `core-template` infrastructure. 

## 1. Environment Preparation
- [ ] Verify execution environment is Ubuntu 24.04.
- [ ] Ensure the AI has `sudo` access or operates as `root`.
- [ ] Verify network connectivity and DNS resolution.
- [ ] Capture existing networking configuration (e.g., `ip a`, `resolvectl status`, `cat /etc/resolv.conf`) to ensure proper rollback if execution fails.
- [ ] Configure variables in `custom-vars.yaml` (`domain`, `host_ip`, `lan_cidr`, etc.).

## 2. Full Installation Test
- [ ] **Action**: Run `sudo ./setup.sh`.
- [ ] **Expected**:
  - Playbooks 00-10 complete successfully without failure.
  - Docker containers `nginx`, `bind9`, `step-ca` (and optionally `openldap`) are healthy.
- [ ] **Validation**: 
  - `docker ps` shows all containers running.
  - `nslookup dns.<domain> localhost -port=5353` returns the host IP.
  - `curl -kI https://ca.<domain>` returns an HTTP 200/404 indicating step-ca is responding.

## 3. Subfunctionality Tests

### 3.1 DNS and Zone Updates
- [ ] **Action**: Modify A/CNAME records in `custom-vars.yaml`.
- [ ] **Action**: Run `sudo ./setup.sh --custom --tags dns-record`.
- [ ] **Expected**: BIND9 reloads zones without restarting the container.
- [ ] **Validation**: Use `dig` to confirm the new records resolve correctly.

### 3.2 PKI / Bring Your Own Certs (BYOC)
- [ ] **Action**: Conduct a teardown (`sudo ./setup.sh --uninstall --force`) to prepare a clean environment.
- [ ] **Action**: Generate an offline Root CA, set `byoc: true` and specify paths in `custom-vars.yaml`.
- [ ] **Action**: Run `sudo ./setup.sh --custom --tags pki`.
- [ ] **Expected**: Step-CA imports the offline CA and restarts.
- [ ] **Validation**: Inspect `/opt/stepca/data/certs/` to confirm the BYOC intermediate cert is present.

### 3.3 Updates (Script/Jinja only)
- [ ] **Action**: Modify a setting in `custom-vars.yaml` (e.g., timezone).
- [ ] **Action**: Run `sudo ./setup.sh --update --apply`.
- [ ] **Expected**: Only configuration templates are re-rendered. Services are not destroyed.

## 4. Teardown
- [ ] **Action**: Run `sudo ./setup.sh --uninstall --force`.
- [ ] **Expected**: All containers, networks, and directories in `/opt/` are destroyed.
- [ ] **Validation**: `docker ps -a` shows no core containers; `ls /opt/core` fails.
