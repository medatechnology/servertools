#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with sudo or as root."
  exit 1
fi

# Detect OS Family
OS_FAMILY="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" == "opensuse"* || "$ID_LIKE" == *"suse"* ]]; then
        OS_FAMILY="suse"
    elif [[ "$ID" == "ubuntu" || "$ID" == "debian" || "$ID_LIKE" == *"debian"* ]]; then
        OS_FAMILY="debian"
    fi
fi

print_header() {
    echo -e "\n=========================================="
    echo -e "🔍 $1"
    echo -e "==========================================\n"
}

print_header "System Info & Overall Disk Usage"
echo "Detected OS Family: ${OS_FAMILY^^}"
df -h /
echo -e "\n📊 All Mounted Filesystems:"
df -hT | grep -vE "tmpfs|devtmpfs|squashfs|overlay" || true

print_header "Checking Top 10 Largest Items in /var/log"
if [ -d "/var/log" ]; then
    du -ah /var/log 2>/dev/null | sort -rh | head -n 10
else
    echo "Directory /var/log not found."
fi

print_header "Checking Systemd Journal Disk Usage"
journalctl --disk-usage

# ==========================================
# OS SPECIFIC CHECKS
# ==========================================

if [ "$OS_FAMILY" == "suse" ]; then
    print_header "openSUSE Specific: Btrfs Snapshots (Snapper)"
    if command -v snapper &> /dev/null; then
        snapper list | head -n 25
        echo -e "\n💡 Tip: If you see dozens of snapshots, they might be hoarding space."
        echo "💡 Tip: Clean up old snapshots on openSUSE using: snapper rm <id-range>"
    else
        echo "Snapper is not actively installed or Btrfs partition layouts differ."
    fi

elif [ "$OS_FAMILY" == "debian" ]; then
    print_header "Ubuntu/Debian Specific: Package Cache & Snaps"

    echo "📦 APT Package Cache Size:"
    du -sh /var/cache/apt/archives 2>/dev/null || echo "N/A"
    echo -e "💡 Tip: You can clear this anytime with: sudo apt-get clean\n"

    if command -v snap &> /dev/null; then
        echo "🛍️ Snap Packages Space Allocation (including revisions):"
        du -sh /var/lib/snapd/snaps 2>/dev/null || echo "No snaps found."
        echo -e "💡 Tip: Ubuntu keeps multiple revisions of core apps here by default."
    else
        echo "Snap daemon (snapd) is not installed on this system."
    fi
fi

print_header "Top 5 Largest Directories Under /var"
du -h --max-depth=2 /var 2>/dev/null | sort -rh | head -n 5

print_header "Added: Top Directories on / (Excluding Virtual & Docker Paths)"
du -h --max-depth=1 / --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/var/lib/docker 2>/dev/null | sort -rh | head -n 10

print_header "Added: Largest Files (>250MB) in Common Paths"
find /var /tmp /home /opt -xdev -type f -size +250M -exec du -h {} + 2>/dev/null | sort -rh | head -n 15 || echo "No files over 250MB found in checked paths."

print_header "Added: Inode Usage on Root (/)"
df -i /

echo -e "\n✅ OS space check complete!\n"
