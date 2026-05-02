# AI Test Plan: Core Template Deployment

**Deployment Domain:** `<domain>`
**Host IP:** `<host_ip>`
**LAN CIDR:** `<lan_cidr>`

This document outlines the testing strategy for an AI agent to execute, validate, and troubleshoot the deployment of the `core-template` infrastructure in offline or standard environments.

## 1. Environment Preparation
- [ ] Verify execution environment is Ubuntu 24.04.
- [ ] Ensure the AI has `sudo` access or operates as `root`.
- [ ] Verify network connectivity and DNS resolution.
- [ ] Capture existing networking configuration (e.g., `ip a`, `resolvectl status`, `cat /etc/resolv.conf`) to ensure proper rollback if execution fails.
- [ ] Variables in `custom-vars.yaml` have been correctly rendered.

## 2. Full Installation Test
- [ ] **Action**: Run `sudo ./setup.sh`.
- [ ] **Expected**:
  - Playbooks 00-10 complete successfully without failure.
  - Docker containers `nginx`, `bind9`, `step-ca` (and optionally `openldap`, `keycloak`, `postgres`) are healthy.
- [ ] **Validation**: 
  - `docker ps` shows all containers running.
  - `nslookup dns.<domain> localhost -port=<bind_dns_port>` returns the host IP.
  - `curl -kI https://ca.<domain>` returns an HTTP response indicating step-ca is up.

## 3. Subfunctionality Tests

### 3.1 DNS and Zone Updates
- [ ] **Action**: Modify A/CNAME records in `custom-vars.yaml` or via `core-mgr`.
- [ ] **Action**: Run `sudo core-mgr --apply`.
- [ ] **Expected**: `core-mgr` detects DNS changes, re-renders templates, and gracefully reloads BIND9 zones without restarting the container.
- [ ] **Validation**: Use `dig` to confirm the new records resolve correctly.

### 3.2 PKI / Bring Your Own Certs (BYOC)
- [ ] **Action**: Conduct a teardown (`sudo ./setup.sh --uninstall --force`) to prepare a clean environment.
- [ ] **Action**: Generate an offline Root CA, set `byoc: true` and specify paths in `custom-vars.yaml`.
- [ ] **Action**: Run `sudo ./setup.sh`.
- [ ] **Expected**: Step-CA imports the offline CA and starts successfully.
- [ ] **Validation**: Inspect `/opt/stepca/data/certs/` to confirm the BYOC intermediate cert is present.

### 3.3 Dynamic Configuration Updates
- [ ] **Action**: Modify a setting in `custom-vars.yaml` (e.g., timezone, domain).
- [ ] **Action**: Run `sudo core-mgr --apply`.
- [ ] **Expected**: Configuration templates are re-rendered and only affected services are restarted or reloaded.

## 4. Teardown
- [ ] **Action**: Run `sudo ./setup.sh --uninstall --force`.
- [ ] **Expected**: All containers, networks, and directories in `/opt/` are destroyed.
- [ ] **Validation**: `docker ps -a` shows no core containers; `ls /opt/core` fails.
