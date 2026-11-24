#!/bin/bash

# Ensure the script is run as root (needed to inspect all container log files)
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with sudo or as root."
  exit 1
fi

print_header() {
    echo -e "\n=========================================="
    echo -e "🐳 $1"
    echo -e "==========================================\n"
}

if ! command -v docker &> /dev/null || ! systemctl is-active --quiet docker; then
    echo "❌ Docker is either not installed or not currently running."
    exit 1
fi

print_header "1. Top 10 Largest Docker Build Cache Layers"
docker builder du --verbose 2>/dev/null | grep -E "ID:|Size:|Description:|Last used:" | head -n 40

print_header "2. Recent Docker Build Events (Last 7 Days)"
docker events --since '168h' --until '0s' --filter 'type=builder' --format '{{.Time}} - {{.Action}} - {{.Actor.Attributes}}' 2>/dev/null | tail -n 20

print_header "3. Running CI/CD & GitOps Containers"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -iE "runner|gitlab|github|jenkins|portainer|coolify|dokku|watchtower|drone|woodpecker|argocd|flux|caprover" || echo "No obvious CI/CD containers found."

print_header "4. Running CI/CD Host Processes"
ps aux | grep -iE "Runner\.Listener|gitlab-runner|jenkins|drone|woodpecker|docker build|docker compose" | grep -v "grep" || echo "No obvious CI/CD host processes found."

print_header "5. Checking Docker Container Log Sizes"
printf "%-10s %-30s %s\n" "SIZE" "CONTAINER NAME" "COMPOSE DIRECTORY"
echo "----------------------------------------------------------------------------------------"

found_logs=false
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

print_header "6. Docker Disk Usage & Build Cache Breakdown"
docker system df
echo -e "\n➡️ Reclaimable Builder Cache Detailed Breakdowns:"
docker builder du 2>/dev/null || docker buildx du 2>/dev/null

print_header "7. Added: Docker Volumes Size Breakdown"
if [ -d "/var/lib/docker/volumes" ]; then
    du -sh /var/lib/docker/volumes/* 2>/dev/null | sort -rh | head -n 15 || echo "No Docker volumes found."
else
    echo "Directory /var/lib/docker/volumes not found."
fi

print_header "8. Added: Exited Containers & Dangling Images"
echo "📦 Exited/Stopped Containers:"
docker ps -a --filter "status=exited" --filter "status=created" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Size}}" || true
echo -e "\n🖼️ Dangling Images:"
docker images -f "dangling=true" --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" || true

echo -e "\n✅ Docker space check complete!\n"
