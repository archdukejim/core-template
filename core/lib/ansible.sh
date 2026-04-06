#!/bin/bash
# Ansible runner — source this file, do not execute directly.

# Run the Ansible playbook
run_playbook() {
    export ANSIBLE_CONFIG="$PLAYBOOKS_DIR/ansible.cfg"
    local tag_args=()
    local conn_args=()
    local become_args=()
    local extra=("$@")

    if [ -n "$ANSIBLE_TAGS" ]; then
        tag_args=(--tags "$ANSIBLE_TAGS")
    fi

    if [ "$TARGET" = "localhost" ] || [ "$TARGET" = "127.0.0.1" ]; then
        conn_args=(--connection=local)
    else
        if ! $_SSH_READY; then
            ensure_ssh_access "$TARGET"
            _SSH_READY=true
        fi
        # Playbook uses become: true — non-root users need sudo password on the remote
        if [ "${SSH_USER}" != "root" ]; then
            become_args=(--ask-become-pass)
        fi
    fi

    local prereqs_arg=()
    if [[ -n "$TARGET_PREREQS_DIR" ]]; then
        prereqs_arg=(-e "offline_prereqs_dir=${TARGET_PREREQS_DIR}")
    fi

    ansible-playbook "$PLAYBOOKS_DIR/core-config.yml" \
        -e "target_host=${TARGET}" \
        -e "ansible_user=${SSH_USER:-root}" \
        -i "${TARGET}," \
        "${conn_args[@]+"${conn_args[@]}"}" \
        "${become_args[@]+"${become_args[@]}"}" \
        "${tag_args[@]+"${tag_args[@]}"}" \
        "${prereqs_arg[@]+"${prereqs_arg[@]}"}" \
        "${extra[@]+"${extra[@]}"}" \
        "${EXTRA_ANSIBLE_ARGS[@]+"${EXTRA_ANSIBLE_ARGS[@]}"}"
}
