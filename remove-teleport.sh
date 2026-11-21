#!/bin/bash

# 1. Ensure the script is run as root/sudo
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with sudo."
  exit 1
fi

echo "🔍 Scanning system for Teleport components..."

FOUND_ITEMS=()

# Check binaries
for bin in teleport tsh tctl tbot; do
    BIN_PATH=$(command -v $bin 2>/dev/null)
    if [ -n "$BIN_PATH" ]; then
        FOUND_ITEMS+=("Binary: $BIN_PATH")
    fi
done

# Check standard directories and config files
PATHS_TO_CHECK=(
    "/etc/teleport.yaml"
    "/etc/teleport.d"
    "/var/lib/teleport"
    "/opt/teleport"
    "/var/log/teleport"
    "/etc/systemd/system/teleport.service"
    "/lib/systemd/system/teleport.service"
    "/usr/lib/systemd/system/teleport.service"
    "/etc/systemd/system/teleport.service.d"
    "/etc/apt/sources.list.d/teleport.list"
    "/etc/yum.repos.d/teleport.repo"
)

for path in "${PATHS_TO_CHECK[@]}"; do
    if [ -e "$path" ]; then
        FOUND_ITEMS+=("Path: $path")
    fi
done

# Check user profiles (.tsh and .tbot)
[ -d "/root/.tsh" ] && FOUND_ITEMS+=("User Data: /root/.tsh")
[ -d "/root/.tbot" ] && FOUND_ITEMS+=("User Data: /root/.tbot")

for user_dir in /home/*; do
    if [ -d "$user_dir/.tsh" ]; then
        FOUND_ITEMS+=("User Data: $user_dir/.tsh")
    fi
    if [ -d "$user_dir/.tbot" ]; then
        FOUND_ITEMS+=("User Data: $user_dir/.tbot")
    fi
done

# Check systemd service status
if systemctl list-unit-files | grep -q "^teleport.service"; then
    FOUND_ITEMS+=("Systemd Service: teleport.service")
fi

# 2. Report findings & ask for confirmation
if [ ${#FOUND_ITEMS[@]} -eq 0 ]; then
    echo "✅ Teleport was NOT found on this system. Nothing to remove!"
    exit 0
fi

echo ""
echo "⚠️  Teleport installation found! The following items will be permanently removed:"
echo "--------------------------------------------------------------------------------"
for item in "${FOUND_ITEMS[@]}"; do
    echo "  • $item"
done
echo "  • Any installed 'teleport' packages via apt/dnf/yum"
echo "  • Running Teleport background processes"
echo "--------------------------------------------------------------------------------"
echo ""

read -p "❓ Are you sure you want to completely remove Teleport? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "🛑 Removal cancelled. No changes were made."
    exit 0
fi

echo ""
echo "🔄 Stopping and disabling Teleport processes..."
systemctl stop teleport 2>/dev/null
systemctl disable teleport 2>/dev/null
pkill -9 -x "teleport|tsh|tctl|tbot" 2>/dev/null

echo "🔄 Purging Teleport from package managers..."
if command -v apt-get &> /dev/null; then
    apt-get purge -y teleport teleport-ent 2>/dev/null
    apt-get autoremove -y 2>/dev/null
elif command -v dnf &> /dev/null; then
    dnf remove -y teleport teleport-ent 2>/dev/null
elif command -v yum &> /dev/null; then
    yum remove -y teleport teleport-ent 2>/dev/null
fi

echo "🔄 Removing binaries..."
for binary in teleport tsh tctl tbot; do
    rm -f "/usr/local/bin/$binary" "/usr/bin/$binary"
    BINARY_PATH=$(command -v $binary 2>/dev/null)
    [ -n "$BINARY_PATH" ] && rm -f "$BINARY_PATH"
done

echo "🔄 Removing systemd service configurations and package repos..."
rm -f /etc/systemd/system/teleport.service
rm -f /lib/systemd/system/teleport.service
rm -f /usr/lib/systemd/system/teleport.service
rm -rf /etc/systemd/system/teleport.service.d
rm -f /etc/apt/sources.list.d/teleport.list
rm -f /etc/yum.repos.d/teleport.repo
systemctl daemon-reload
systemctl reset-failed 2>/dev/null

echo "🔄 Deleting system directories and configuration files..."
rm -rf /etc/teleport.yaml /etc/teleport.d /var/lib/teleport /opt/teleport /var/log/teleport

echo "🔄 Cleaning up user profile caches (.tsh and .tbot)..."
rm -rf ~/.tsh ~/.tbot /root/.tsh /root/.tbot

if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    rm -rf "$USER_HOME/.tsh" "$USER_HOME/.tbot"
fi

for user_dir in /home/*; do
    if [ -d "$user_dir" ]; then
        rm -rf "$user_dir/.tsh" "$user_dir/.tbot"
    fi
done

echo ""
echo "✨ Verification Check:"
LEFTOVERS=$(command -v teleport tsh tctl tbot 2>/dev/null)
if [ -z "$LEFTOVERS" ] && [ ! -d "/opt/teleport" ] && [ ! -d "/var/lib/teleport" ] && [ ! -f "/etc/teleport.yaml" ]; then
    echo "✅ Teleport has been 100% completely removed!"
else
    echo "⚠️  Warning: Some files could not be removed automatically. Please check manually:"
    echo "   $LEFTOVERS"
fi

echo ""
echo "📋 Post-Removal Steps:"
echo "  1. No system reboot is required."
echo "  2. If you added Teleport to your shell PATH in ~/.bashrc or ~/.zshrc, remove those lines manually."
echo "  3. If this machine was a Teleport Node/Agent, remove it from your Teleport Cluster Web UI (or run 'tctl nodes rm <node-name>' on your Auth server) so it doesn't show as offline."
echo "  4. Close any custom firewall ports you opened specifically for Teleport (e.g., 3022-3025, 3080, 443)."
