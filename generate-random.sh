#!/bin/bash

# 1. Ask for length
read -p "Enter desired character length (e.g., 32): " LENGTH
if [[ ! "$LENGTH" =~ ^[0-9]+$ ]]; then
  echo "❌ Please enter a valid number."
  exit 1
fi

# 2. Ask for character set type
echo "Choose character set:"
echo "1) Alphanumeric only (A-Z, a-z, 0-9)"
echo "2) Alphanumeric + Symbols"
echo "3) Alphabetic only (A-Z, a-z)"
read -p "Select choice (1-3): " CHARSET_CHOICE

# Define filter sets based on user choice
case "$CHARSET_CHOICE" in
  1) FILTER='A-Za-z0-9' ;;
  2) FILTER='A-Za-z0-9!@#$%^&*()_+=-{}[]' ;;
  3) FILTER='A-Za-z' ;;
  *) echo "❌ Invalid selection."; exit 1 ;;
esac

echo "-----------------------------------"
echo "🔑 Your generated key:"

# 3. Generate the secure random string
# We read 4x the length from openssl to ensure we have enough bytes after filtering
openssl rand -base64 "$((LENGTH * 4))" | tr -dc "$FILTER" | head -c "$LENGTH"
echo "" # Prints a newline at the end
echo "-----------------------------------"

