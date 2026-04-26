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
    *   By default, Keycloak and PostgreSQL use UIDs `1000` and `999` respectively. However, we have upgraded to Keycloak 26 and PostgreSQL 18 and enforce custom UIDs: `900` for Keycloak and `901` for PostgreSQL.
    *   **Gotcha (Keycloak)**: Keycloak 26 requires write access to `/opt/keycloak/lib/quarkus` to compile its optimized bytecode during startup. If you run it as `user: "900:900"`, it will crash with an `AccessDeniedException` because user `900` cannot write to the container's root-owned library directories.
    *   **Solution**: Run Keycloak with `user: "900:0"`. By running with GID `0` (the root group), Keycloak gains group-write permissions to the internal directories while still maintaining UID `900` isolation on the host.
    *   **Gotcha (PostgreSQL)**: PostgreSQL 16+ introduces strict mount point boundaries. If you map `/opt/postgres/data` directly to `/var/lib/postgresql/data`, PostgreSQL will refuse to initialize, citing that the directory is an `(unused mount/volume)`.
    *   **Solution**: Set the `PGDATA` environment variable to a subdirectory, e.g., `/var/lib/postgresql/data/pgdata`. PostgreSQL will successfully create and manage this subdirectory.
*   **kcadm.sh Configuration**:
    *   **Gotcha**: When Keycloak runs as a non-root user (e.g. UID 900), its home directory evaluates to `/`, which it cannot write to. Running `kcadm.sh` commands will fail with `Failed to create config file: /.keycloak/kcadm.config`.
    *   **Solution**: Append `--config /tmp/kcadm.config` immediately after the `kcadm.sh` command (e.g., `kcadm.sh config credentials --config /tmp/kcadm.config ...`) to write the configuration to a writable temporary directory.
*   **Healthchecks and Systemd**: 
    *   Keycloak 24+ running on Quarkus does not enable health endpoints by default.
    *   **Gotcha**: If `KC_HEALTH_ENABLED: "true"` is not explicitly set in the Keycloak environment variables, the systemd `ExecStartPost` health check will fail (timing out after 60 seconds), causing dependent services like `nginx` to fail to start. Also, Keycloak 26 removed `curl` from its base image, causing Docker healthchecks relying on `curl` to fail.
    *   **Solution**: The docker-compose `test` command must rely on bash TCP streams (e.g., `exec 3<>/dev/tcp/127.0.0.1/9000`) instead of `curl` to query `/health/ready`.

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
*   **Gotcha**: Keycloak connection URL must use the exact LDAP hostname (`ldaps://{{ hostname_ldap }}:636`) instead of just `ldaps://ldap:636`. Using the bare `ldap` name fails resolution (`UnknownHostException`) because it's not a valid Docker alias on the network, only `hostname_ldap` is.

---
*End of Phase 3 Notes*

## Phase 4: Security & ACLs

### OpenLDAP Configuration Database (cn=config)
*   **Gotcha**: The default `osixia/openldap` image processes files in `/container/environment/custom/` during startup. However, if a file ends in `.ldif`, it runs it against the main database using a simple bind (`ldapadd -x`). 
*   **Solution**: To modify the `cn=config` database, you MUST execute `ldapmodify -Y EXTERNAL -H ldapi:///`. We achieved this by writing `06-acl.sh` instead of an `.ldif` file, allowing the shell script to execute the proper `ldapmodify` command.

### TLS Enforcement and Simple Binds
*   **Gotcha**: OpenLDAP is configured to strictly enforce TLS (`LDAP_TLS_ENFORCE: "true"`). Running simple binds (`ldapadd -x` or `ldapsearch -x`) against `localhost` or `ldapi:///` will fail with `Confidentiality required (13)`.
*   **Solution**: Any local testing or script execution against the OpenLDAP container must use `-H ldaps://localhost:636` and override TLS verification with `LDAPTLS_REQCERT=never` if querying internally.

### Isolated Permissions Testing
*   Keycloak's ability to create, read, and write users and groups was successfully validated using the isolated `cn=keycloak_admin` service account.
*   The `cn=config` Access Control Lists ensure that the Keycloak service account has write access *only* to `ou=users` and `ou=groups`, preventing it from recursively modifying core infrastructure accounts like `cn=super_admin`.
