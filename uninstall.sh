#!/bin/bash

# Define the custom service accounts to be removed
# (Excluding root and user_default for system safety)

echo "Compose Down"

docker compose -f /opt/core/docker-compose.yml down -v

echo "Compose Prune"

docker network prune -f

echo "Docker tasked finished"

SERVICE_USERS=("nginx" "bind" "step" "ldap" "certbot" "adguard")

echo "Starting cleanup of service accounts..."

for user in "${SERVICE_USERS[@]}"; do
    if id "$user" &>/dev/null; then
        echo "Removing user: $user..."
        
        # -r removes the home directory and mail spool
        # We use || as a fallback in case -r fails due to busy files
        userdel -r "$user" 2>/dev/null || userdel "$user"
        
        if [ $? -eq 0 ]; then
            echo "Successfully removed $user."
        else
            echo "Failed to remove $user. It might be in use by a running process."
        fi
    else
        echo "User $user does not exist, skipping."
    fi
done

echo "changing to /opt directory"
cd /opt

echo "remvoing folders: adguardhome/ bind9/ certbot/ easyrsa/ nginx/ openldap/ step-ca/ stepca/"
rm -r -f adguardhome/ bind9/ certbot/ easyrsa/ nginx/ openldap/ step-ca/ stepca/

echo "Cleanup complete. Ready for re-installation."