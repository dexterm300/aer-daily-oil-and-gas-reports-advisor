terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.region
}

############################
# S3 bucket for raw files  #
############################
resource "aws_s3_bucket" "raw" {
  bucket = var.raw_bucket_name
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

############################
# Lambda packaging         #
############################
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "lambda"
  output_path = "aer_downloader.zip"
}

resource "aws_iam_role" "lambda_exec" {
  name               = "aer_downloader_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action   = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name        = "aer_downloader_policy"
  description = "Allow Lambda to access S3, SNS, Bedrock, and logs"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = ["s3:ListBucket"],
        Resource = [
          aws_s3_bucket.raw.arn
        ]
      },
      {
        Effect = "Allow",
        Action = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"],
        Resource = [
          "${aws_s3_bucket.raw.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = ["sns:Publish"],
        Resource = [aws_sns_topic.summary.arn]
      },
      {
        Effect = "Allow",
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_lambda_function" "aer_downloader" {
  function_name = "aer_downloader"
  role          = aws_iam_role.lambda_exec.arn
  runtime       = "python3.11"
  handler       = "aer_downloader.handler"
  filename      = data.archive_file.lambda_zip.output_path

  environment {
    variables = {
      RAW_BUCKET  = aws_s3_bucket.raw.bucket
      MODEL_ID    = var.bedrock_model_id
      SNS_TOPIC_ARN = aws_sns_topic.summary.arn
    }
  }

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 120
}

############################
# EventBridge Scheduler    #
############################
resource "aws_iam_role" "scheduler_invoke" {
  name               = "aer_scheduler_invoke_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = { Service = "scheduler.amazonaws.com" },
        Action   = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "scheduler_policy" {
  name   = "aer_scheduler_invoke_lambda"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["lambda:InvokeFunction"],
        Resource = [aws_lambda_function.aer_downloader.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "scheduler_attach" {
  role       = aws_iam_role.scheduler_invoke.name
  policy_arn = aws_iam_policy.scheduler_policy.arn
}

resource "aws_lambda_permission" "allow_scheduler" {
  statement_id  = "AllowExecutionFromScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aer_downloader.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.st1.arn
}

resource "aws_lambda_permission" "allow_scheduler_st100" {
  statement_id  = "AllowExecutionFromSchedulerST100"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aer_downloader.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.st100.arn
}

resource "aws_scheduler_schedule" "st1" {
  name                         = "aer-st1-1015"
  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(15 10 * * ? *)"   # 10:15 daily
  schedule_expression_timezone = "America/Edmonton"

  target {
    arn      = aws_lambda_function.aer_downloader.arn
    role_arn = aws_iam_role.scheduler_invoke.arn
    input    = jsonencode({ dataset = "ST1" })
  }
}

resource "aws_scheduler_schedule" "st100" {
  name                         = "aer-st100-2120"
  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(20 21 ? * MON-FRI *)"   # 21:20 Mon-Fri
  schedule_expression_timezone = "America/Edmonton"

  target {
    arn      = aws_lambda_function.aer_downloader.arn
    role_arn = aws_iam_role.scheduler_invoke.arn
    input    = jsonencode({ dataset = "ST100" })
  }
}

############################
# SNS topic + subscription #
############################
resource "aws_sns_topic" "summary" {
  name = "aer-daily-summary"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.summary.arn
  protocol  = "email"
  endpoint  = var.recipient_email
}


