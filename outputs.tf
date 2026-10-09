output "api_url" {
  description = "Base URL for the orders API"
  value       = "https://${aws_api_gateway_rest_api.orders_api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.orders_api_stage.stage_name}"
}