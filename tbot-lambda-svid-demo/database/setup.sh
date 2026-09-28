#!/usr/bin/env bash
# Prepares certs for the demo Postgres:
#   certs/spiffe-ca.pem   Teleport SPIFFE CA  -> Postgres ssl_ca_file (verifies client SVIDs)
#   certs/server-ca.pem   throwaway CA         -> given to the Lambda to verify the server
#   certs/server.{crt,key} server cert for DB_HOST
#
# Usage: ./setup.sh <db-hostname-or-ip>
# Requires: tctl (logged in to your cluster), openssl
#
# Logged into more than one proxy? Pin tctl to the right cluster (the notebook
# does this for you from .env; see TELEPORT_AUTH_SERVER there):
#
#   TELEPORT_AUTH_SERVER=mycluster.teleport.sh:443 ./setup.sh <db-host>
#
# The CA subject printed below tells you which cluster it actually came from.
set -euo pipefail

DB_HOST="${1:?usage: $0 <db-hostname-or-ip>}"
cd "$(dirname "$0")"
mkdir -p certs
cd certs

echo "==> Exporting Teleport SPIFFE CA"
tctl auth export --type tls-spiffe > spiffe-ca.pem
openssl x509 -in spiffe-ca.pem -noout -subject -enddate

echo "==> Creating server CA + cert for ${DB_HOST}"
if [[ "${DB_HOST}" =~ ^[0-9.]+$ ]]; then SAN="IP:${DB_HOST}"; else SAN="DNS:${DB_HOST}"; fi

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
  -subj "/CN=tbot-lambda-demo postgres CA" \
  -keyout server-ca.key -out server-ca.pem 2>/dev/null

openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=${DB_HOST}" -keyout server.key -out server.csr 2>/dev/null

openssl x509 -req -in server.csr -CA server-ca.pem -CAkey server-ca.key -CAcreateserial \
  -days 365 -out server.crt \
  -extfile <(printf "subjectAltName=%s\nextendedKeyUsage=serverAuth\n" "${SAN}") 2>/dev/null

rm -f server.csr
echo "==> Done. Install Postgres with: ./deploy-postgres.sh ${DB_HOST} <ssh-key>"
