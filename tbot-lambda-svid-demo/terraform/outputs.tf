output "function_name" {
  value = aws_lambda_function.demo.function_name
}

output "expected_join_arn" {
  description = "The STS ARN Teleport expects tbot to join as."
  value       = local.lambda_sts_arn
}

output "spiffe_id_path" {
  value = teleport_workload_identity.lambda.spec.spiffe.id
}

output "invoke_command" {
  value = "aws lambda invoke --region ${var.aws_region} --function-name ${aws_lambda_function.demo.function_name} --cli-binary-format raw-in-base64-out --payload '{}' /dev/stdout | jq ."
}
