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

# Formatting helpers
print_header() {
    echo -e "\n=========================================="
    echo -e "🔍 $1"
    echo -e "==========================================\n"
}

print_header "System Info & Overall Disk Usage"
echo "Detected OS Family: ${OS_FAMILY^^}"
df -h /

print_header "Checking Top 10 Largest Items in /var/log"
if [ -d "/var/log" ]; then
    du -ah /var/log 2>/dev/null | sort -rh | head -n 10
else
    echo "Directory /var/log not found."
fi

print_header "Checking Systemd Journal Disk Usage"
journalctl --disk-usage

print_header "Checking Docker Container Log Sizes"
if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
    printf "%-10s %-30s %s\n" "SIZE" "CONTAINER NAME" "COMPOSE DIRECTORY"
    echo "----------------------------------------------------------------------------------------"
    
    found_logs=false
    # Use find to cleanly catch files even if globbing behavior varies slightly between shells
    while IFS= read -r log_path; do
        [ -f "$log_path" ] || continue
        found_logs=true
        
        size=$(du -sh "$log_path" | awk '{print $1}')
        container_id=$(basename "$log_path" | sed 's/-json.log//')
        
        container_name=$(docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's/\///')
        compose_dir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container_id" 2>/dev/null)
        
        if [ -z "$container_name" ]; then
            container_name="[Orphaned Log]"
            compose_dir="N/A (Container Deleted)"
        elif [ -z "$compose_dir" ]; then
            compose_dir="N/A (Standalone Container)"
        fi
        
        printf "%-10s %-30s %s\n" "$size" "$container_name" "$compose_dir"
    done < <(find /var/lib/docker/containers/ -name "*-json.log" 2>/dev/null) | sort -rh
    
    if [ "$found_logs" = false ]; then
        echo "No Docker container logs found."
    fi
else
    echo "Docker is either not installed or not currently running."
fi

print_header "Deep Dive: Docker Disk Cache (Build Cache Info)"
if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
    docker system df
    echo -e "\n➡️ Reclaimable Builder Cache Detailed Breakdowns:"
    docker builder du 2>/dev/null || docker buildx du 2>/dev/null
else
    echo "Docker details unavailable."
fi

# ==========================================
# OS SPECIFIC CHECKS
# ==========================================

if [ "$OS_FAMILY" == "suse" ]; then
    print_header "openSUSE Specific: Btrfs Snapshots (Snapper)"
    if command -v snapper &> /dev/null; then
        snapper list | head -n 25
        echo -e "\n💡 Tip: Clean up old snapshots on openSUSE using: snapper rm <id-range>"
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

print_header "Bonus: Top 5 Largest Directories Under /var"
# Walks through /var where databases, packages, and dockers stash hidden bloat
du -h --max-depth=2 /var 2>/dev/null | sort -rh | head -n 5

echo -e "\n✅ Universal cross-platform check complete!\n"
