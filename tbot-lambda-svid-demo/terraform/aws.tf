data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  in_vpc     = length(var.subnet_ids) > 0

  # The identity tbot presents when it joins via the IAM method. Lambda always
  # uses the function name as the role session name.
  lambda_sts_arn = "arn:aws:sts::${local.account_id}:assumed-role/${aws_iam_role.lambda.name}/${var.name}"

  socket = "unix:///tmp/tbot/workload.sock"
}

# --- Execution role ----------------------------------------------------------
# Note: no Teleport- or DB-specific permissions. The role's *identity* is what
# Teleport trusts (sts:GetCallerIdentity needs no IAM permission).

resource "aws_iam_role" "lambda" {
  name = "${var.name}-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "vpc" {
  count      = local.in_vpc ? 1 : 0
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = 7
}

# --- tbot extension layer ----------------------------------------------------

resource "aws_lambda_layer_version" "tbot" {
  layer_name               = "${var.name}-tbot"
  filename                 = var.layer_zip
  source_code_hash         = filebase64sha256(var.layer_zip)
  compatible_architectures = [var.lambda_architecture]
  compatible_runtimes      = ["provided.al2023"]
  description              = "Teleport tbot as a Lambda extension serving the SPIFFE Workload API"
}

# --- Function ----------------------------------------------------------------

resource "aws_lambda_function" "demo" {
  function_name    = var.name
  role             = aws_iam_role.lambda.arn
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  architectures    = [var.lambda_architecture]
  filename         = var.function_zip
  source_code_hash = filebase64sha256(var.function_zip)
  layers           = [aws_lambda_layer_version.tbot.arn]

  # tbot is a ~100 MB Go binary; give it room and CPU for a fast cold start.
  memory_size = 512
  timeout     = 30

  environment {
    variables = {
      # Read by the tbot extension
      TELEPORT_PROXY_ADDR    = var.teleport_proxy_addr
      TBOT_JOIN_TOKEN        = teleport_provision_token.lambda.metadata.name
      TBOT_WORKLOAD_IDENTITY = teleport_workload_identity.lambda.metadata.name

      # Read by both the extension (listen address) and go-spiffe (dial address)
      SPIFFE_ENDPOINT_SOCKET = local.socket

      # Read by the handler: reuse the SVID across warm invokes, or not.
      SVID_CACHE = tostring(var.svid_cache)

      # Read by the handler
      DB_HOST          = var.db_host
      DB_PORT          = tostring(var.db_port)
      DB_NAME          = var.db_name
      DB_USER          = var.svid_common_name
      DB_SSLMODE       = var.db_sslmode
      DB_SERVER_CA_PEM = var.db_server_ca_pem_file == "" ? "" : file(var.db_server_ca_pem_file)
    }
  }

  dynamic "vpc_config" {
    for_each = local.in_vpc ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.logs,
    aws_cloudwatch_log_group.fn,
    # Teleport objects must exist before the first cold start tries to join.
    teleport_bot.lambda,
    teleport_role.lambda_wi_issuer,
  ]
}
