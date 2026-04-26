# Keycloak Deployment Documentation

This document tracks connections, variables, configuration nuances, and gotchas discovered during the Keycloak OpenLDAP integration deployment.

## Phase 1: Infrastructure and Bootstrapping

### Configuration Variables
*   **Keycloak Installation**: Enabled via `install_keycloak: true` in `custom-vars.yaml`.
*   **Host IP**: Ensure `host_ip` is correctly set in `custom-vars.yaml`. Mismatched IPs will cause Nginx (and other containers) to fail when binding ports.

### Secrets and Credentials
*   **LDAP Service Account**: Keycloak uses a dedicated, isolated service account password (`ldap_keycloak_password`) generated automatically by `01-handle-vars.yml` and stored in `core-secrets.yml`.
*   **Keycloak Admin**: The admin credentials (`keycloak_admin_user`, `keycloak_admin_password`) and the PostgreSQL database password (`keycloak_db_password`) are also generated automatically by `01-handle-vars.yml`.

### Identity Preconditioning & Gotchas
*   **Container UIDs vs Host UIDs**: 
    *   The official Keycloak container image enforces running as UID `1000` (`keycloak`) by default to manage internal files (like generated Quarkus bytecode). 
    *   Similarly, the official PostgreSQL image defaults to UID `999`.
    *   **Gotcha**: On standard Ubuntu/Linux hosts, UID `1000` is often already assigned to the default administrative user (e.g., `default_admin`), and UID `999` is assigned to `lxd` or `systemd-journal`.
    *   **Solution**: We explicitly run the containers as their default UIDs (`1000` and `999`) and allow the host directory bind mounts (`/opt/keycloak/data` and `/opt/postgres/data`) to be owned by whatever host user maps to those IDs. We modified the identity preconditioning playbook (`03-target-service-accounts.yml`) to warn rather than fail when these UIDs are already in use.
*   **Healthchecks and Systemd**: 
    *   Keycloak 24+ running on Quarkus does not enable health endpoints by default.
    *   **Gotcha**: If `KC_HEALTH_ENABLED: "true"` is not explicitly set in the Keycloak environment variables, the systemd `ExecStartPost` health check will fail (timing out after 60 seconds), causing dependent services like `nginx` to fail to start.
    *   **Solution**: Added `KC_HEALTH_ENABLED: "true"` to `core/jinja/keycloak/docker-compose.yml.j2`.

---
*End of Phase 1 Notes*
