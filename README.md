# AER Daily Briefing – Terraform Deployment

This project deploys a serverless pipeline that:
- Downloads AER ST1 and ST100 files on schedule
- Stores them briefly in S3 `dex-s3-bucket-aer-files-raw`
- Summarizes contents using Amazon Bedrock
- Publishes the summary to an SNS topic with an email subscription
- Deletes the files from S3 after publish

## Prerequisites
- AWS CLI credentials already configured
- Permissions to use: S3, Lambda, EventBridge Scheduler, IAM, SNS, Bedrock
- SNS email subscriptions require you to confirm the subscription from your inbox
- Bedrock model access enabled for the chosen model in the target region

## Variables (you will be prompted)
- `region` (required): AWS region for all resources (e.g., `ca-central-1`)
- `recipient_email`
- `raw_bucket_name`
- `bedrock_model_id` (default `anthropic.claude-3-5-sonnet-20241022-v2:0`)

## Deploy
```bash
terraform init
terraform apply
# You will be prompted for region
```

After `apply` completes:
- Check your inbox for an SNS subscription confirmation email and confirm it.

## Schedules (America/Edmonton time)
- ST1: 10:15 daily
- ST100: 21:20 Monday–Friday

## Lambda environment
- `RAW_BUCKET` → S3 bucket
- `SNS_TOPIC_ARN` → SNS topic for summary
- `MODEL_ID` → Bedrock model

## Manual run (Linux/WSL)
Invoke and print logs + result:
```bash
aws lambda invoke \
  --function-name aer_downloader \
  --payload '{"dataset":"ST1"}' \
  out.json --cli-binary-format raw-in-base64-out --log-type Tail \
  --query 'LogResult' --output text | base64 -d
cat out.json | jq .
```
Change to `ST100` as needed.

## Backfilling a specific date
Temporarily set `REPORT_DATE=YYYY-MM-DD` in the Lambda environment, invoke, then remove it.

## Destroy
```bash
terraform destroy
```

