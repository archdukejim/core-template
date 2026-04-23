# Maintenance and Updates

### Table of Contents: Update Options
- [Updating Scripts (`setup.sh --update`)](#updating-scripts-setupsh---update)
  - [`--review`](#--review)
  - [`--apply`](#--apply)
  - [`--force`](#--force)
  - [`--custom --tags`](#--custom---tags)
- [In-Place Upgrades (`setup.sh --upgrade`)](#in-place-upgrades-setupsh---upgrade)
  - [`--add-ldap`](#--add-ldap)
  - [`--only-existing`](#--only-existing)
  - [`--offline`](#--offline)
  - [`--apply`](#--apply-1)
- [Uninstall (`setup.sh --uninstall`)](#uninstall-setupsh---uninstall)
  - [`--force`](#--force-1)
- [Version Tracking](#version-tracking)
  - [`--export`](#--export)

---

## Updating Scripts (`setup.sh --update`)

`--update` mode re-renders scripts and static files from the current repo without touching live service configs. A snapshot of `/opt/core/` is automatically archived before every update.

Files updated: `setup.sh`, `manage.sh`, `cert-relay-host.sh`, `cert-update.sh`, PKI info page.

### `--review`
Show full file diffs without applying (update mode).
```bash
# 1. Standard review of pending updates
sudo ./setup.sh --update --review

# 2. Review updates for a specific tag
sudo ./setup.sh --update --review --custom --tags bind9
```

### `--apply`
Apply updates silently without interactive prompting.
```bash
# 1. Apply script updates non-interactively
sudo ./setup.sh --update --apply

# 2. Apply updates and force overwrite configs non-interactively
sudo ./setup.sh --update --force --apply
```

### `--force`
Overwrite live configs in addition to scripts.
```bash
# 1. Interactive prompt but will overwrite configs if accepted
sudo ./setup.sh --update --force

# 2. Apply forcefully non-interactively
sudo ./setup.sh --update --force --apply
```

### `--custom --tags`
Run specific playbook sections by tag.
```bash
# 1. Update only the nginx configurations
sudo ./setup.sh --update --custom --tags nginx

# 2. Update and force apply specific tags
sudo ./setup.sh --update --force --apply --custom --tags pki
```

---

## In-Place Upgrades (`setup.sh --upgrade`)

Use `setup.sh --upgrade` to seamlessly upgrade an existing deployment to inherit new structural features and updated Docker images while preserving your live variables and configuration state.

It extracts your active `vars.yaml` from the live target (`/opt/core/vars.yaml`), archives a backup snapshot to `/opt/core/archive/`, and seamlessly merges your localized state onto the newest template variable definitions. It then coordinates an image pull, drops the container stack cleanly if structural changes arise, redeploys the new file hierarchy, and brings the stack back online.

### `--add-ldap`
Perform an in-place upgrade to include the OpenLDAP component and its directory structure.
```bash
# 1. In-place deploy OpenLDAP component
sudo ./setup.sh --upgrade --add-ldap
```

### `--only-existing`
Upgrades existing containers/tooling but skips new features.
```bash
# 1. Upgrade without adding new stack features
sudo ./setup.sh --upgrade --only-existing

# 2. Upgrade only existing features non-interactively
sudo ./setup.sh --upgrade --only-existing --apply
```

### `--offline`
Fails proactively if new images are not locally cached.
```bash
# 1. Upgrade in offline mode
sudo ./setup.sh --upgrade --offline

# 2. Offline upgrade without prompts
sudo ./setup.sh --upgrade --offline --apply
```

### `--apply`
Non-interactive execution.
```bash
# 1. Standard non-interactive full upgrade
sudo ./setup.sh --upgrade --apply

# 2. Apply combined with offline restriction
sudo ./setup.sh --upgrade --offline --apply
```

During an upgrade, the **Target Deployment Structure** is managed as follows:
- **Preserved (Persistent):** All your customizations in `vars.yaml` are merged safely. Runtime data such as Step-CA certificates/databases (`/opt/stepca/data/certs`, `config`, etc.), BIND9 runtime caches and dynamic journals, OpenLDAP user databases (`/opt/openldap/data` and `config`), and all existing snapshot archives in `/opt/core/archive`.
- **Overwritten (Managed):** Core configuration files derived from the latest templates including `/opt/core/docker-compose.yml`, `/opt/nginx/nginx.conf`, BIND9 static configs (`/opt/bind9/config/*`) and zone definitions (`/opt/bind9/data/db.*`), OpenLDAP `.ldif` configurations, and Step-CA rendering templates (`leaf.tpl`, `subca.tpl`).

---

## Uninstall (`setup.sh --uninstall`)

Stops and removes all containers, removes service accounts, and deletes `/opt/{core,nginx,bind9,stepca,openldap}/`. Interactive — offers to save a backup snapshot and confirms before proceeding.

### `--force`
Skip backup offers and confirmation prompt.
```bash
# 1. Interactive uninstall with backup prompts
sudo ./setup.sh --uninstall

# 2. Force wipe immediately with no backup
sudo ./setup.sh --uninstall --force
```

---

## Version Tracking

Every rendered file includes a version stamp in its header so you can trace any deployed config back to its source commit.

### `--export`
Captures all rendered configs in a git-tracked directory. Each export is one commit — `git diff` between two exports shows exactly what changed in the deployed environment.

```bash
# 1. Export to default builds directory
sudo ./setup.sh --export ./builds/

# 2. Export to a custom path
sudo ./setup.sh --export /tmp/core-snapshot/
```
