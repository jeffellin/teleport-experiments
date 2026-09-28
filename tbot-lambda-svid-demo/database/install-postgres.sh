#!/usr/bin/env bash
# Installs and configures PostgreSQL for the tbot SVID demo on a bare host.
#
# Run this ON the database host, as root:
#
#   sudo ./install-postgres.sh [source-dir]
#
# source-dir defaults to this script's own directory and must contain:
#   server.crt  server.key  spiffe-ca.pem  pg_hba.conf  init.sql
# Generate the first three with ./setup.sh <db-host-or-ip>.
#
# The end state, which is the whole point of the demo:
#   ssl_ca_file = spiffe-ca.pem  -> Postgres trusts client certs issued by the
#                                   Teleport SPIFFE CA
#   pg_hba.conf                  -> the only remotely reachable line is
#                                   `hostssl demo lambda_svid_demo ... cert`
#   role lambda_svid_demo        -> LOGIN, no password; the client cert's CN
#                                   must equal this name
#
# Env overrides: PG_MAJOR (default 17), PGDATA (default /var/lib/pgsql/data).
# Safe to re-run.
set -euo pipefail

PG_MAJOR="${PG_MAJOR:-17}"
PGDATA="${PGDATA:-/var/lib/pgsql/data}"
SRC="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
MARKER="# --- tbot SVID demo ---"

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root (use sudo)" >&2; exit 1; }

for f in server.crt server.key spiffe-ca.pem pg_hba.conf init.sql; do
  [[ -f "$SRC/$f" ]] || { echo "ERROR: missing $SRC/$f" >&2; exit 1; }
done

echo "==> postgresql${PG_MAJOR}-server"
if rpm -q "postgresql${PG_MAJOR}-server" >/dev/null 2>&1; then
  echo "    already installed"
else
  dnf install -y "postgresql${PG_MAJOR}-server"
fi

echo "==> initdb ($PGDATA)"
if [[ -f "$PGDATA/PG_VERSION" ]]; then
  echo "    already initialized"
else
  postgresql-setup --initdb
fi

# Postgres refuses to start if its key file is group- or world-readable.
echo "==> certs + pg_hba.conf"
install -o postgres -g postgres -m 0644 "$SRC/server.crt"    "$PGDATA/server.crt"
install -o postgres -g postgres -m 0600 "$SRC/server.key"    "$PGDATA/server.key"
install -o postgres -g postgres -m 0644 "$SRC/spiffe-ca.pem" "$PGDATA/spiffe-ca.pem"
install -o postgres -g postgres -m 0600 "$SRC/pg_hba.conf"   "$PGDATA/pg_hba.conf"

echo "==> postgresql.conf"
if grep -qF "$MARKER" "$PGDATA/postgresql.conf"; then
  echo "    demo block already present"
else
  # Appended, so these override the defaults earlier in the file.
  # listen_addresses is essential: a stock initdb listens on localhost only,
  # which looks like a security-group problem from the Lambda's side.
  cat >> "$PGDATA/postgresql.conf" <<CONF

$MARKER
listen_addresses = '*'
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
ssl_ca_file = 'spiffe-ca.pem'
log_connections = on
CONF
  chown postgres:postgres "$PGDATA/postgresql.conf"
fi

echo "==> service"
systemctl enable postgresql >/dev/null 2>&1 || true
systemctl restart postgresql   # restart so cert/config changes apply on re-runs

for _ in $(seq 1 30); do
  sudo -u postgres pg_isready -q && break
  sleep 1
done
if ! sudo -u postgres pg_isready; then
  echo "ERROR: postgres did not become ready" >&2
  journalctl -u postgresql -n 40 --no-pager >&2 || true
  exit 1
fi

echo "==> database + schema"
# init.sql creates the role and table but not the database itself.
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='demo'" | grep -q 1; then
  echo "    database demo exists"
else
  sudo -u postgres createdb demo
fi
if sudo -u postgres psql -d demo -tAc "SELECT to_regclass('lambda_invocations') IS NOT NULL" | grep -q t; then
  echo "    schema already present"
else
  # Redirect rather than psql -f: $SRC is mode 0700 (it holds server.key), so the
  # postgres user can't open the file itself. The root shell opens it here and
  # psql inherits the descriptor.
  sudo -u postgres psql -q -d demo < "$SRC/init.sql"
fi

echo
echo "==> verification"
sudo -u postgres psql -d demo -c 'show ssl' -c 'show ssl_ca_file' -c 'show listen_addresses'
sudo -u postgres psql -d demo -c '\du lambda_svid_demo'
sudo -u postgres psql -d demo -c '\dp lambda_invocations'
ss -lntp 2>/dev/null | grep ':5432' || true

echo
echo "Postgres accepts client certificates issued by:"
openssl x509 -in "$PGDATA/spiffe-ca.pem" -noout -subject
echo "Watch authentication attempts with: journalctl -u postgresql -f"
