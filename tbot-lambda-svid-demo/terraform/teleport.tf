# The Teleport side of the demo:
#
#   workload_identity  what the SVID looks like + who may get it
#   role               lets the bot issue that workload identity
#   bot                the machine identity tbot runs as
#   provision_token    IAM join: "whoever holds this Lambda's role may be the bot"

locals {
  wi_labels = { "demo" = var.name }

  # Rules evaluated by the Teleport Auth Service at issuance time.
  # - join.iam.arn: the bot joined from *this* Lambda's execution role/session
  # - workload.unix.binary_path: the caller on the socket is the function binary,
  #   not some other process in the sandbox (attested by tbot via SO_PEERCRED + /proc)
  wi_conditions = [
    for c in [
      {
        attribute = "join.iam.arn"
        eq        = { value = local.lambda_sts_arn }
      },
      {
        attribute = "workload.unix.binary_path"
        eq        = { value = "/var/task/bootstrap" }
      },
    ] : c if c.attribute != "workload.unix.binary_path" || var.require_binary_path
  ]
}

resource "teleport_workload_identity" "lambda" {
  version = "v1"
  metadata = {
    name   = var.name
    labels = local.wi_labels
  }
  spec = {
    spiffe = {
      # e.g. spiffe://example.teleport.sh/aws/lambda/123456789012/tbot-svid-demo
      # `{{ }}` is Teleport templating (not Terraform interpolation).
      id   = "/aws/lambda/{{ join.iam.account }}/${var.name}"
      hint = "postgres-client"
      x509 = {
        maximum_ttl = var.svid_ttl
        # Postgres `cert` auth maps the certificate CN to the DB role.
        subject_template = {
          common_name  = var.svid_common_name
          organization = "Teleport Workload Identity Demo"
        }
      }
    }
    rules = {
      allow = [{ conditions = local.wi_conditions }]
    }
  }
}

resource "teleport_role" "lambda_wi_issuer" {
  version = "v7"
  metadata = {
    name        = "${var.name}-wi-issuer"
    description = "Allows the Lambda bot to issue the ${var.name} workload identity"
  }
  spec = {
    allow = {
      workload_identity_labels = { for k, v in local.wi_labels : k => [v] }
      rules = [{
        resources = ["workload_identity"]
        verbs     = ["list", "read"]
      }]
    }
  }
}

resource "teleport_bot" "lambda" {
  metadata = {
    name = var.name
  }
  spec = {
    roles = [teleport_role.lambda_wi_issuer.metadata.name]
  }
}

resource "teleport_provision_token" "lambda" {
  version = "v2"
  metadata = {
    name        = "${var.name}-iam"
    description = "IAM join for Lambda ${var.name}"
  }
  spec = {
    roles       = ["Bot"]
    bot_name    = teleport_bot.lambda.metadata.name
    join_method = "iam"
    allow = [{
      aws_account = local.account_id
      aws_arn     = local.lambda_sts_arn
    }]
  }
}
