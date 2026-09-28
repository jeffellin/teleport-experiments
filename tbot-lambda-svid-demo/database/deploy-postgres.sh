#!/usr/bin/env bash
# Ships this directory's Postgres config to a remote host and runs
# install-postgres.sh there. Run from your workstation.
#
#   ./setup.sh <db-host-or-ip>                 # first: mint the certs
#   ./deploy-postgres.sh <host> [ssh-key] [ssh-user]
#
# Example (host created by ../terraform/db):
#   ./setup.sh 18.232.63.143
#   ./deploy-postgres.sh 18.232.63.143 ../terraform/db/tbot-svid-demo.pem
#
# Requires passwordless sudo for the SSH user (the default on Amazon Linux).
set -euo pipefail

HOST="${1:?usage: $0 <host> [ssh-key] [ssh-user]}"
KEY="${2:-}"
SSH_USER="${3:-ec2-user}"
cd "$(dirname "$0")"

[[ -f certs/server.crt ]] || {
  echo "ERROR: certs/ not found - run ./setup.sh $HOST first" >&2; exit 1; }

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "$KEY" ]] && SSH_OPTS+=(-i "$KEY")

echo "==> copying to ${SSH_USER}@${HOST}:/tmp/pgsetup"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" 'install -d -m 0700 /tmp/pgsetup'
scp "${SSH_OPTS[@]}" -q \
  certs/server.crt certs/server.key certs/spiffe-ca.pem \
  pg_hba.conf init.sql install-postgres.sh \
  "${SSH_USER}@${HOST}:/tmp/pgsetup/"

echo "==> running installer on ${HOST}"
# /tmp/pgsetup holds the server private key, so remove it whether or not the
# installer succeeds, and preserve its exit code.
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" '
  chmod +x /tmp/pgsetup/install-postgres.sh
  sudo /tmp/pgsetup/install-postgres.sh /tmp/pgsetup
  rc=$?
  rm -rf /tmp/pgsetup
  exit $rc'
