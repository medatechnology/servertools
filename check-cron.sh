echo -e "\n=========================================="
echo "1. CRON JOBS FOR ALL USERS & SYSTEM"
echo "=========================================="
# Check every user on the system
for user in $(cut -f1 -d: /etc/passwd); do
    CRON_OUT=$(crontab -u "$user" -l 2>/dev/null | grep -v "^#" | grep -iE "docker|build|deploy|compose|sh")
    if [ -n "$CRON_OUT" ]; then
        echo "--- User: $user ---"
        echo "$CRON_OUT"
    fi
done
# Check system-wide cron directories
grep -rnE "docker|build|deploy|compose" /etc/crontab /etc/cron.* /var/spool/cron/ 2>/dev/null

echo -e "\n=========================================="
echo "2. SYSTEMD TIMERS & SERVICES"
echo "=========================================="
systemctl list-timers --all --no-pager | grep -iE "docker|build|deploy|backup|git" || echo "No matching systemd timers found."
grep -rnE "docker build|docker compose" /etc/systemd/system/ 2>/dev/null
