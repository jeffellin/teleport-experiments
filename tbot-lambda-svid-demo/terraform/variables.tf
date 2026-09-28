variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "teleport_proxy_addr" {
  description = "Teleport Proxy address incl. port, e.g. example.teleport.sh:443"
  type        = string
}

variable "name" {
  description = "Base name for the Lambda function, IAM role, bot, token and workload identity."
  type        = string
  default     = "tbot-svid-demo"
}

variable "lambda_architecture" {
  description = "arm64 or x86_64. Must match the ARCH used with `make` (arm64 / amd64)."
  type        = string
  default     = "arm64"
}

variable "layer_zip" {
  type    = string
  default = "../build/tbot-layer.zip"
}

variable "function_zip" {
  type    = string
  default = "../build/function.zip"
}

# --- Workload identity -------------------------------------------------------

variable "svid_common_name" {
  description = "CN placed in the X509-SVID subject. With Postgres `cert` auth this must equal the DB role name."
  type        = string
  default     = "lambda_svid_demo"
}

variable "svid_ttl" {
  description = "Maximum TTL of issued X509-SVIDs."
  type        = string
  default     = "1h"
}

variable "require_binary_path" {
  description = "Also require the workload (Unix attestation) to be /var/task/bootstrap. Set false if attestation fails in your environment."
  type        = bool
  default     = true
}

# --- Database ----------------------------------------------------------------

variable "db_host" {
  description = "Postgres hostname (must match the server cert SAN when db_sslmode = verify-full). Empty = skip DB step."
  type        = string
  default     = ""
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type    = string
  default = "demo"
}

variable "db_sslmode" {
  description = "verify-full (recommended; needs db_server_ca_pem_file) or require (no server verification)."
  type        = string
  default     = "verify-full"
}

variable "db_server_ca_pem_file" {
  description = "Path to the CA that signed the Postgres server cert (database/certs/server-ca.pem from setup.sh)."
  type        = string
  default     = ""
}

# --- Networking (only if the DB lives in a private VPC) ----------------------

variable "subnet_ids" {
  description = "Private subnets for the Lambda. They need a NAT/egress path to the Teleport Proxy. Empty = no VPC."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  type    = list(string)
  default = []
}
