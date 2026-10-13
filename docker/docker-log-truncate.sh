#!/bin/bash

# Ensure the script is run as root/sudo to access Docker log files
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with sudo."
  exit 1
fi

echo "🔍 Scanning Docker containers..."

# Arrays to store container info
declare -A container_paths
declare -A container_names
declare -A compose_projects

# Get all running and stopped containers
mapfile -t containers < <(docker ps -a --format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.project"}}')

if [ ${#containers[@]} -eq 0 ]; then
  echo "ℹ️ No containers found."
  exit 0
fi

# Parse container details
index=1
for item in "${containers[@]}"; do
  # Skip completely empty lines
  [ -z "$item" ] && continue
  
  IFS='|' read -r c_id c_name c_project <<< "$item"
  
  # Get the absolute path to the json log file
  log_path=$(docker inspect --format='{{.LogPath}}' "$c_id" 2>/dev/null)
  
  if [ -n "$log_path" ] && [ "$log_path" != "<no value>" ] && [ "$log_path" != "null" ]; then
    container_paths[$index]=$log_path
    container_names[$index]=$c_name
    
    # If part of a compose project, group it
    if [ -n "$c_project" ]; then
      compose_projects["$c_project"]+="$index "
    fi
    ((index++))
  fi
done

total_containers=$((index - 1))

echo "============================================="
echo "        DOCKER LOG TRUNCATOR MENU            "
echo "============================================="
echo "A) [ALL] Truncate logs for ALL containers"
echo ""

# Display Compose Projects
declare -A compose_menu_map
if [ ${#compose_projects[@]} -gt 0 ]; then
  echo "--- DOCKER COMPOSE PROJECTS ---"
  c_idx=1
  for project in "${!compose_projects[@]}"; do
    # Skip if project key is empty
    [ -z "$project" ] && continue
    
    echo "C$c_idx) Project: $project"
    # Show containers inside this project
    for idx in ${compose_projects[$project]}; do
      echo "    ↳ ${container_names[$idx]}"
    done
    compose_menu_map["C$c_idx"]=$project
    compose_menu_map["c$c_idx"]=$project # Support lowercase input directly
    ((c_idx++))
  done
  echo ""
fi

# Display Individual Containers
echo "--- INDIVIDUAL CONTAINERS ---"
for ((i=1; i<=total_containers; i++)); do
  echo "$i) ${container_names[$i]}"
done
echo "============================================="

# Ask user for input
read -p "Select an option (e.g., A, 1, C1): " choice

# Function to truncate a specific index
truncate_index() {
  local idx=$1
  local path="${container_paths[$idx]}"
  local name="${container_names[$idx]}"
  
  if [ -f "$path" ]; then
    local size_before
    size_before=$(du -sh "$path" | cut -f1)
    truncate -s 0 "$path"
    echo "⚡ Truncated $name ($size_before -> 0B)"
  else
    echo "ℹ️ $name has no active log file on disk."
  fi
}

# Process User Choice
case "$choice" in
  [Aa])
    echo "⚠️ Wiping logs for ALL containers..."
    for ((i=1; i<=total_containers; i++)); do
      truncate_index "$i"
    done
    ;;
    
  C*|c*)
    project_name="${compose_menu_map[$choice]}"
    
    if [ -n "$project_name" ]; then
      echo "📂 Wiping logs for Compose Project: $project_name..."
      for idx in ${compose_projects[$project_name]}; do
        truncate_index "$idx"
      done
    else
      echo "❌ Invalid Compose Project selection."
    fi
    ;;
    
  *)
    # Check if choice is a valid individual container number
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le "$total_containers" ] && [ "$choice" -gt 0 ]; then
      echo "📱 Wiping log for single container..."
      truncate_index "$choice"
    else
      echo "❌ Invalid selection."
    fi
    ;;
esac

echo "✅ Done."

