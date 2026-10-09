terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

############################
# DynamoDB orders table
############################

resource "aws_dynamodb_table" "orders" {
  name           = "orders"
  billing_mode   = "PAY_PER_REQUEST" # Simple billing mode
  hash_key       = "orderId"

  attribute {
    name = "orderId"
    type = "S"
  }

  # Enable stream for outbox pattern
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  tags = {
    Project = "event-driven-orders"
  }
}

############################
# SQS Queues (payment + DLQ)
############################

resource "aws_sqs_queue" "payment_dlq" {
  name                      = "payment-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "payment_queue" {
  name                       = "payment-queue"
  visibility_timeout_seconds = 60      # Must be >= Lambda timeout
  message_retention_seconds  = 345600  # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.payment_dlq.arn
    maxReceiveCount     = 3 # Max retries > 3 requirement
  })
}

############################
# SNS Topic (order-notifications)
############################

resource "aws_sns_topic" "order_notifications" {
  name = "order-notifications"
}

############################
# Email Subscription
############################

resource "aws_sns_topic_subscription" "order_notifications_email" {
  topic_arn = aws_sns_topic.order_notifications.arn
  protocol  = "email"
  endpoint  = "your-email@simulation.com" # fil your email here for testing
}

############################
# IAM Roles for Lambdas
############################

# Lambda 1: CreateOrderFn role
resource "aws_iam_role" "lambda_create_order_role" {
  name = "lambda-create-order-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Basic execution policy (logs)
resource "aws_iam_role_policy_attachment" "lambda_create_order_basic_execution" {
  role       = aws_iam_role.lambda_create_order_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy for DynamoDB access
resource "aws_iam_role_policy" "lambda_create_order_dynamodb_policy" {
  name = "lambda-create-order-dynamodb-policy"
  role = aws_iam_role.lambda_create_order_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.orders.arn
      }
    ]
  })
}

# Lambda 2: ProcessPaymentFn role
resource "aws_iam_role" "lambda_process_payment_role" {
  name = "lambda-process-payment-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Basic execution policy (logs)
resource "aws_iam_role_policy_attachment" "lambda_process_payment_basic_execution" {
  role       = aws_iam_role.lambda_process_payment_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy for SQS, DynamoDB, SNS
resource "aws_iam_role_policy" "lambda_process_payment_policy" {
  name = "lambda-process-payment-policy"
  role = aws_iam_role.lambda_process_payment_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.payment_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.orders.arn
      },
      {
        Effect   = "Allow"
        Action   = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.order_notifications.arn
      }
    ]
  })
}

############################
# Lambda Functions
############################

resource "aws_lambda_function" "create_order_fn" {
  function_name = "CreateOrderFn"
  role          = aws_iam_role.lambda_create_order_role.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"

  filename         = "${path.module}/lambda_create_order/index.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda_create_order/index.zip")

  timeout = 10 # Simple timeout

  environment {
    variables = {
      ORDERS_TABLE_NAME = aws_dynamodb_table.orders.name
    }
  }
}

resource "aws_lambda_function" "get_order_status_fn" {
  function_name = "GetOrderStatusFn"
  role          = aws_iam_role.lambda_create_order_role.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"

  filename         = "${path.module}/lambda_get_order_status/index.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda_get_order_status/index.zip")

  timeout = 10 # Simple timeout

  environment {
    variables = {
      ORDERS_TABLE_NAME = aws_dynamodb_table.orders.name
    }
  }
}

resource "aws_lambda_function" "process_payment_fn" {
  function_name = "ProcessPaymentFn"
  role          = aws_iam_role.lambda_process_payment_role.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"

  filename         = "${path.module}/lambda_process_payment/index.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda_process_payment/index.zip")

  timeout = 30 # Must be <= SQS visibility timeout

  environment {
    variables = {
      ORDERS_TABLE_NAME      = aws_dynamodb_table.orders.name
      SNS_TOPIC_ARN          = aws_sns_topic.order_notifications.arn
      PAYMENT_SUCCESS_RATE   = "0.8" # 80% success simulation
    }
  }
}

############################
# Event Source Mapping (SQS -> Lambda 2)
############################

resource "aws_lambda_event_source_mapping" "sqs_to_process_payment" {
  event_source_arn  = aws_sqs_queue.payment_queue.arn
  function_name     = aws_lambda_function.process_payment_fn.arn
  batch_size        = 10
  enabled           = true

  # Enable partial batch response for fine-grained retries
  function_response_types = ["ReportBatchItemFailures"]
}

############################
# DynamoDB Streams -> SQS (Outbox pattern)
############################

# Simple Lambda bridge from DynamoDB Stream to SQS
# Note: In real production, you might use EventBridge Pipes or direct integration.
# Here we use a small Lambda for clarity and demo friendly approach.

resource "aws_iam_role" "lambda_stream_to_sqs_role" {
  name = "lambda-stream-to-sqs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_stream_to_sqs_basic_execution" {
  role       = aws_iam_role.lambda_stream_to_sqs_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_stream_to_sqs_policy" {
  name = "lambda-stream-to-sqs-policy"
  role = aws_iam_role.lambda_stream_to_sqs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "dynamodb:DescribeStream",
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:ListStreams"
        ]
        Resource = aws_dynamodb_table.orders.stream_arn
      },
      {
        Effect   = "Allow"
        Action   = [
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.payment_queue.arn
      }
    ]
  })
}

resource "aws_lambda_function" "stream_to_sqs_fn" {
  function_name = "OrdersStreamToSqsFn"
  role          = aws_iam_role.lambda_stream_to_sqs_role.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"

  filename         = "${path.module}/lambda_stream_to_sqs/index.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda_stream_to_sqs/index.zip")

  timeout = 10

  environment {
    variables = {
      PAYMENT_QUEUE_URL = aws_sqs_queue.payment_queue.id
    }
  }
}

resource "aws_lambda_event_source_mapping" "dynamodb_stream_to_sqs" {
  event_source_arn  = aws_dynamodb_table.orders.stream_arn
  function_name     = aws_lambda_function.stream_to_sqs_fn.arn
  batch_size        = 100
  starting_position = "LATEST"
  enabled           = true
}

############################
# API Gateway (REST API)
############################

resource "aws_api_gateway_rest_api" "orders_api" {
  name        = "orders-api"
  description = "Orders API for event-driven payment flow"
}

# Root resource is "/"
data "aws_api_gateway_resource" "root" {
  rest_api_id = aws_api_gateway_rest_api.orders_api.id
  path        = "/"
}

# /orders resource
resource "aws_api_gateway_resource" "orders_resource" {
  rest_api_id = aws_api_gateway_rest_api.orders_api.id
  parent_id   = data.aws_api_gateway_resource.root.id
  path_part   = "orders"
}

# POST /orders method
resource "aws_api_gateway_method" "orders_post" {
  rest_api_id   = aws_api_gateway_rest_api.orders_api.id
  resource_id   = aws_api_gateway_resource.orders_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

# Lambda integration for POST /orders
resource "aws_api_gateway_integration" "orders_post_integration" {
  rest_api_id = aws_api_gateway_rest_api.orders_api.id
  resource_id = aws_api_gateway_resource.orders_resource.id
  http_method = aws_api_gateway_method.orders_post.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri         = aws_lambda_function.create_order_fn.invoke_arn
}

# Permission for API Gateway to invoke Lambda 1
resource "aws_lambda_permission" "apigw_invoke_create_order" {
  statement_id  = "AllowAPIGatewayInvokeCreateOrder"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.create_order_fn.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.orders_api.execution_arn}/*/POST/orders"
}

# /orders/{orderId} resource
resource "aws_api_gateway_resource" "orders_orderid_resource" {
  rest_api_id = aws_api_gateway_rest_api.orders_api.id
  parent_id   = aws_api_gateway_resource.orders_resource.id
  path_part   = "{orderId}"
}

# GET /orders/{orderId} method
resource "aws_api_gateway_method" "orders_get" {
  rest_api_id   = aws_api_gateway_rest_api.orders_api.id
  resource_id   = aws_api_gateway_resource.orders_orderid_resource.id
  http_method   = "GET"
  authorization = "NONE"
}

# Lambda integration for GET /orders/{orderId}
resource "aws_api_gateway_integration" "orders_get_integration" {
  rest_api_id             = aws_api_gateway_rest_api.orders_api.id
  resource_id             = aws_api_gateway_resource.orders_orderid_resource.id
  http_method             = aws_api_gateway_method.orders_get.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.get_order_status_fn.invoke_arn
}

# Permission for API Gateway to invoke GetOrderStatusFn
resource "aws_lambda_permission" "apigw_invoke_get_order_status" {
  statement_id  = "AllowAPIGatewayInvokeGetOrderStatus"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_order_status_fn.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.orders_api.execution_arn}/*/GET/orders/*"
}

# Deployment and stage
resource "aws_api_gateway_deployment" "orders_api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.orders_api.id

  depends_on = [
    aws_api_gateway_integration.orders_post_integration,
    aws_api_gateway_integration.orders_get_integration
  ]
}

resource "aws_api_gateway_stage" "orders_api_stage" {
  rest_api_id   = aws_api_gateway_rest_api.orders_api.id
  deployment_id = aws_api_gateway_deployment.orders_api_deployment.id
  stage_name    = "dev"
}

############################
# Outputs
############################

output "api_invoke_url" {
  description = "Invoke URL for POST /orders"
  value       = "https://${aws_api_gateway_rest_api.orders_api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.orders_api_stage.stage_name}/orders"
}

output "orders_table_name" {
  value = aws_dynamodb_table.orders.name
}

output "payment_queue_url" {
  value = aws_sqs_queue.payment_queue.id
}

output "sns_topic_arn" {
  value = aws_sns_topic.order_notifications.arn
}