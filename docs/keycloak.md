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

## Phase 3: LDAP Federation Configuration

### Keycloak Provider Configuration (kcadm.sh)
*   **kcadm.sh Connection**: When running `kcadm.sh config credentials` inside the Keycloak container, using `--server https://localhost:8443` will fail with a `SunCertPathBuilderException` because the internal Java truststore does not automatically trust the generated certificates without explicit Java keystore configuration. 
    *   **Gotcha**: Using `--insecure` does not bypass this specific PKIX path building failure in Keycloak 24.
    *   **Solution**: Connect to the local HTTP port instead: `--server http://localhost:8080`.
*   **Property Naming in Keycloak 24**:
    *   **Gotcha**: When configuring the `group-ldap-mapper` via `kcadm.sh`, older camelCase property names (e.g., `groupsDn`, `groupNameLDAPAttribute`) will fail with errors like `Missing configuration for LDAP Groups DN`.
    *   **Solution**: Keycloak 24 expects dot-separated property names (e.g., `groups.dn`, `group.name.ldap.attribute`).
    *   **Gotcha 2**: When using `kcadm.sh` with the `-s` flag, properties with dots are parsed as nested JSON objects unless the keys are explicitly quoted.
    *   **Solution**: You must quote the keys: `-s 'config."groups.dn"=["ou=groups,{{ ldap_base_dn }}"]'`.

### LDAP Service Account Bind
*   Keycloak is now bound to OpenLDAP using the dedicated `cn=keycloak_admin,ou=admins,ou=accounts,{{ ldap_base_dn }}` service account, utilizing the isolated `ldap_keycloak_password`.
*   Users are searched in `ou=users,ou=accounts,{{ ldap_base_dn }}`.
*   Groups are searched in `ou=groups,{{ ldap_base_dn }}`.
