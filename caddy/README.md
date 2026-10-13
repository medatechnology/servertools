# Run reverse proxy using Caddy

## First check if network already exist
Run the script createNetwork, this is safe to run because it checks if network exist then it just skips

## Run Caddy
Just run docker compose up -d

## Adding new service
Modify Caddyfile, add new one then run
docker compose restart
