variable "region" {
  description = "AWS region to deploy into (will be prompted)"
  type        = string
}

variable "raw_bucket_name" {
  description = "S3 bucket name for raw AER files"
  type        = string
  default     = "(INSERT-BUCKET-NAME)"
}

variable "recipient_email" {
  description = "Recipient email address for the daily summary"
  type        = string
  default     = "(INSERT-RECIPIENT-EMAIL)"
}

variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID (e.g., anthropic.claude-3-haiku-20240307)"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}


