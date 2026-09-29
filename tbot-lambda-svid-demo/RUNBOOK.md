# CLI runbook

The same demo as `demo-walkthrough.ipynb`, driven from a shell. Useful for CI, for a
terminal-only demo, or when you want to see exactly what the notebook is doing.

`README.md` has the prerequisites, the architecture, and the reasoning behind each choice. This
file is just the sequence.

Run everything from the project root. Total time from nothing to a working demo is about
5 minutes, most of it `terraform apply` and the Postgres install.

Every command here is POSIX and works unchanged in **bash and zsh** — `set -a` is `allexport`
in both, and the blocks avoid bashisms. Verified on zsh 5.9 and bash 5.x.

---

## 0. Configure

`.env` is the single source of truth. Fill it in first, source it **once**, then derive
everything the tools read from it.

### 0a. Find the values you need

Two of them come from AWS. This uses your normal credential chain, not `.env`.

```bash
cp .env.example .env

# Your public IP as a /32, ready to paste into ADMIN_CIDR.
echo "$(curl -s https://checkip.amazonaws.com)/32"

# The Postgres host needs a PUBLIC subnet -- one whose effective route table
# sends 0.0.0.0/0 to an internet gateway.
aws ec2 describe-route-tables --output table --query \
 'RouteTables[].{rt:RouteTableId,vpc:VpcId,main:Associations[0].Main,subnets:join(`,`,Associations[?SubnetId!=null].SubnetId),igw:Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId|[0]}'
```

Read that table as: a row with an `igw-` in the `igw` column is public. If it lists subnets, those
are public. If `main` is `True`, **every subnet in that VPC without its own association inherits
it too** — which is why a naive "find explicitly-associated subnets" query misses them.

### 0b. Edit `.env`

Set these four, then don't touch the file again:

```
TELEPORT_PROXY_ADDR=mycluster.teleport.sh:443
VPC_ID=vpc-xxxxxxxx
SUBNET_ID=subnet-xxxxxxxx
ADMIN_CIDR=203.0.113.10/32
```

### 0c. Source it and derive the rest

```bash
set -a; . ./.env; set +a

# tsh reads TELEPORT_PROXY; tctl ignores that and reads TELEPORT_AUTH_SERVER.
# Both are needed -- setting one pins only half the calls.
export TELEPORT_PROXY="$TELEPORT_PROXY_ADDR"
export TELEPORT_AUTH_SERVER="${TELEPORT_AUTH_SERVER:-$TELEPORT_PROXY_ADDR}"

export AWS_REGION="${AWS_REGION:-us-east-1}"
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_teleport_proxy_addr="$TELEPORT_PROXY_ADDR"
export TF_VAR_name="${DEMO_NAME:-tbot-svid-demo}"
export TF_VAR_private_key_path="$HOME/.ssh/${DEMO_NAME:-tbot-svid-demo}.pem"
export TF_VAR_vpc_id="$VPC_ID"
export TF_VAR_subnet_id="$SUBNET_ID"

# Accept a bare IP or a full CIDR in .env, and detect it if absent. A bare IP
# would be rejected by the AWS API, so normalise to /32 here.
case "${ADMIN_CIDR:-}" in
  "")  ADMIN_CIDR="$(curl -s https://checkip.amazonaws.com)/32" ;;
  */*) ;;
  *)   ADMIN_CIDR="$ADMIN_CIDR/32" ;;
esac
export TF_VAR_admin_cidr="$ADMIN_CIDR"

echo "cluster    = $TELEPORT_AUTH_SERVER"
echo "vpc        = $TF_VAR_vpc_id"
echo "subnet     = $TF_VAR_subnet_id"
echo "admin_cidr = $TF_VAR_admin_cidr"
```

Check none of those four are blank before continuing.

> **Source `.env` once.** If you edit it later and re-source, do it *before* this export block,
> not after — `.env.example` ships `TELEPORT_AUTH_SERVER=` empty, so re-sourcing on its own would
> reset it to blank and silently un-pin `tctl`.

> **`terraform.tfvars` beats `TF_VAR_*`.** Terraform's precedence puts `terraform.tfvars` above
> environment variables, so if one exists — the notebook writes them into `terraform/` and
> `terraform/db/` — these exports are silently ignored. Delete those files for the CLI path, or
> edit them instead of exporting.

`vpc_id`, `subnet_id`, and `admin_cidr` have no defaults in the module, so Terraform refuses to
apply rather than guessing. (The notebook derives all three automatically, walking both explicit
and main route-table associations — more code than belongs in a runbook.)

## 1. Verify you're pointed at the right places

Check both before creating anything.

```bash
aws sts get-caller-identity
tctl status | head -3
```

The cluster in the second output is where the bot, token, and workload identity will be created.

## 2. Create the Postgres host

`terraform/db` is a separate root module — it has to be applied before the main one, because the
main module needs the instance's IP and the server CA.

```bash
terraform -chdir=terraform/db init
terraform -chdir=terraform/db apply

export DB_HOST=$(terraform -chdir=terraform/db output -raw public_ip)
export KEY=$TF_VAR_private_key_path
chmod 600 "$KEY"
echo "db_host=$DB_HOST"
```

Wait for sshd — a fresh instance needs 20–40 seconds:

```bash
until ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      ec2-user@"$DB_HOST" true 2>/dev/null; do echo waiting; sleep 5; done
echo "ssh ready"
```

## 3. Mint the certificates

Exports your cluster's SPIFFE CA (which Postgres will trust) plus a throwaway server CA and
cert for `$DB_HOST`.

```bash
(cd database && ./setup.sh "$DB_HOST")
openssl x509 -in database/certs/spiffe-ca.pem -noout -subject
```

Confirm that subject names the cluster you expect — this is the step where a wrong
`TELEPORT_AUTH_SERVER` would silently poison everything downstream.

## 4. Install and configure Postgres

Copies the certs, `pg_hba.conf`, and `init.sql` to the host and runs the installer there as
root. No container runtime involved.

```bash
(cd database && ./deploy-postgres.sh "$DB_HOST" "$KEY")
```

The output ends with a verification block: `ssl on`, `ssl_ca_file` pointing at the SPIFFE CA,
`listen_addresses *`, the `lambda_svid_demo` role, and the table grants.

Check it's reachable from outside AWS:

```bash
nc -z -w5 "$DB_HOST" 5432 && echo "5432 reachable"
```

## 5. Build

`TELEPORT_VERSION` comes from the live cluster so the shipped `tbot` matches it.

```bash
go mod tidy
make TELEPORT_VERSION="$(tctl status | awk '/^Version/ {print $2}')" ARCH="${ARCH:-arm64}"
ls -lh build/*.zip
```

`build/tbot-layer.zip` must stay under **50 MB** — that's Lambda's inline upload limit. It lands
around 30 MB.

## 6. Deploy the Lambda and the Teleport resources

Nine resources: IAM role, log group, layer, and function on the AWS side; `workload_identity`,
`role`, `bot`, and `provision_token` on the Teleport side.

```bash
export TF_VAR_db_host="$DB_HOST"
export TF_VAR_db_sslmode=verify-full
export TF_VAR_db_server_ca_pem_file=../database/certs/server-ca.pem

eval "$(tctl terraform env)"     # short-lived provider credentials, ~1h
terraform -chdir=terraform init
terraform -chdir=terraform apply
terraform -chdir=terraform output
```

`tctl terraform env` provisions a temporary bot in your cluster. It expires on its own but shows
up in `tctl bots instances ls`.

## 7. Test

```bash
eval "$(terraform -chdir=terraform output -raw invoke_command)"
```

Success looks like:

```json
{
  "svid": {
    "spiffe_id": "spiffe://<cluster>/aws/lambda/<account>/tbot-svid-demo",
    "subject": "CN=lambda_svid_demo,O=Teleport Workload Identity Demo",
    "reused": false,
    "expires_in": "59m32s"
  },
  "database": {
    "current_user": "lambda_svid_demo",
    "ssl_client_dn": "/O=Teleport Workload Identity Demo/CN=lambda_svid_demo"
  },
  "timings_ms": { "fetch_svid": 425, "db_connect": 11, "db_query": 10 }
}
```

`ssl_client_dn` being populated is the proof: Postgres authenticated a **certificate**, and the
role has no password.

Invoke again — the second one should show `"reused": true` with `fetch_svid` near zero, because
the handler keeps an `X509Source` in memory across warm invokes:

```bash
eval "$(terraform -chdir=terraform output -raw invoke_command)"
```

## 8. Confirm it from the other side

Don't take the function's word for it.

```bash
# The bot instance that didn't exist before the first invoke, joined via iam
tctl bots instances ls | grep -E "ID|${DEMO_NAME:-tbot-svid-demo}"

# The cold start: extension registering, tbot joining
aws logs tail "/aws/lambda/${DEMO_NAME:-tbot-svid-demo}" --since 15m --format short \
  | grep -iE 'INIT_START|tbot-extension|Fetched new bot identity'

# Postgres's own account of the authentication
ssh -i "$KEY" ec2-user@"$DB_HOST" \
  'sudo grep -h "connection authorized" $(ls -t /var/lib/pgsql/data/log/*.log | head -1) | tail -3'
```

That last one prints `user=lambda_svid_demo ... SSL enabled (protocol=TLSv1.3, ...)`.

## 9. Negative tests

```bash
# No client certificate -> rejected. TCP connects; authentication does not.
ssh -i "$KEY" ec2-user@"$DB_HOST" \
  "psql 'host=$DB_HOST dbname=demo user=lambda_svid_demo sslmode=require' -c 'select 1'"

# The function holds no secrets, only names and a public CA
aws lambda get-function-configuration --function-name "${DEMO_NAME:-tbot-svid-demo}" \
  --query Environment.Variables | jq 'del(.DB_SERVER_CA_PEM)'
```

## 10. Tear down

The instance bills ~$7/month until you do.

```bash
eval "$(tctl terraform env)"
terraform -chdir=terraform destroy
terraform -chdir=terraform/db destroy
```

Destroys all 17 resources, including the EC2 instance, its EBS volume, the key pair, and the
local `.pem`. Your pre-existing VPC, subnet, and internet gateway are untouched.

Not covered: the temporary `tctl-terraform-env-*` bots (they expire), and local files under
`database/certs/` and `build/`.

---

## If something fails

| Where | Look at |
|---|---|
| Step 2, no subnet found | You need a public subnet — default route to an `igw-`, not a `nat-`. Set `SUBNET_ID` in `.env`. |
| Step 2, SSH times out | `ADMIN_CIDR` isn't your current IP. It changes when your network does. |
| Step 3, wrong CA subject | `TELEPORT_AUTH_SERVER` is pointing at another cluster. |
| Step 7, `Extension.TbotNotReady` | The Lambda can't reach the proxy, or the join ARN doesn't match `terraform output expected_join_arn`. |
| Step 7, `db connect` error | Security group, `listen_addresses`, or a `db_host` that doesn't match the cert SAN. |

`README.md` has the full troubleshooting table and explains why each of these happens.
