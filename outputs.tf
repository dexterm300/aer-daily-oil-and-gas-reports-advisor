output "lambda_function_name" {
  value       = aws_lambda_function.aer_downloader.function_name
  description = "Name of the deployed Lambda function"
}

output "raw_bucket" {
  value       = aws_s3_bucket.raw.bucket
  description = "S3 bucket used for raw files"
}

output "st1_schedule_arn" {
  value       = aws_scheduler_schedule.st1.arn
  description = "ARN of the ST1 scheduler"
}

output "st100_schedule_arn" {
  value       = aws_scheduler_schedule.st100.arn
  description = "ARN of the ST100 scheduler"
}


