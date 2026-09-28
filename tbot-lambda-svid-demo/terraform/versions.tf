terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = ">= 18.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Auth for the Teleport provider comes from the environment, e.g.:
#   tsh login --proxy=example.teleport.sh
#   eval "$(tctl terraform env)"
# See https://goteleport.com/docs/zero-trust-access/infrastructure-as-code/terraform-provider/
provider "teleport" {
  addr = var.teleport_proxy_addr
}
