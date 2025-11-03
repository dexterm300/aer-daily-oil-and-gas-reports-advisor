import os
import json
import hashlib
import urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import boto3
from botocore.exceptions import ClientError


ALBERTA_TZ = ZoneInfo("America/Edmonton")

S3 = boto3.client("s3")
SNS = boto3.client("sns")
BEDROCK = boto3.client("bedrock-runtime")

RAW_BUCKET = os.environ["RAW_BUCKET"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
MODEL_ID = os.environ["MODEL_ID"]


def previous_business_day(day):
    while day.weekday() > 4:
        day -= timedelta(days=1)
    return day


def resolve_report_date(dataset: str, now_utc: datetime | None = None):
    override = os.getenv("REPORT_DATE")
    if override:
        return datetime.strptime(override, "%Y-%m-%d").date()

    if now_utc is None:
        now_utc = datetime.utcnow().replace(tzinfo=ZoneInfo("UTC"))
    now_ab = now_utc.astimezone(ALBERTA_TZ)
    day = now_ab.date()

    if dataset == "ST1":
        if now_ab.hour < 10:
            day = previous_business_day(day - timedelta(days=1))
        else:
            day = previous_business_day(day)
    elif dataset == "ST100":
        if now_ab.weekday() > 4:
            day = previous_business_day(day)
        elif now_ab.hour < 21:
            day = previous_business_day(day - timedelta(days=1))
        else:
            day = previous_business_day(day)
    else:
        raise ValueError(f"Unknown dataset {dataset}")

    return day


def build_url(dataset: str, day):
    mmdd = day.strftime("%m%d")
    if dataset == "ST1":
        return f"https://static.aer.ca/data/well-lic/WELLS{mmdd}.txt"
    if dataset == "ST100":
        return f"https://static.aer.ca/prd/data/pipeconst/PIPE{mmdd}.txt"
    raise ValueError(f"Unknown dataset {dataset}")


def s3_key(day, dataset, ext="txt"):
    return f"{day:%Y/%m/%d}/{dataset.lower()}_{day:%Y%m%d}.{ext}"


def http_get(url: str):
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            status = resp.getcode()
            data = resp.read()
            return status, data
    except urllib.error.HTTPError as e:
        return e.code, None


def summarize_with_bedrock(day, items):
    text_blocks = []
    for it in items:
        text = it["preview"]
        trimmed = text[:8000]
        text_blocks.append(f"Dataset {it['dataset']} ({day:%Y-%m-%d}):\n{trimmed}")

    prompt = (
        "You are an oil & gas analyst.\n"
        "Summarize today's AER releases (ST1 well licenses, ST100 pipeline construction notices).\n"
        "Provide:\n"
        "- Key totals and notable entries\n"
        "- Any unusual spikes vs typical days\n"
        "- Operator or region callouts\n"
        "- Short, actionable insights\n\n"
        f"Text:\n\n{chr(10).join(text_blocks)}"
    )

    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 700,
        "temperature": 0.2,
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": prompt}]}
        ],
    })

    resp = BEDROCK.invoke_model(
        modelId=MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=body,
    )
    resp_body = json.loads(resp["body"].read())
    return resp_body["content"][0]["text"]


def publish_sns(subject: str, message: str):
    SNS.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)


def handler(event, _ctx):
    dataset = event["dataset"]  # "ST1" or "ST100"
    day = resolve_report_date(dataset)
    url = build_url(dataset, day)

    status, content = http_get(url)
    if status == 404:
        return {"dataset": dataset, "date": f"{day:%Y-%m-%d}", "status": "not_ready", "url": url}
    if status is None or status >= 400:
        raise RuntimeError(f"Failed to download {url}: status={status}")

    sha = hashlib.sha256(content).hexdigest()
    key = s3_key(day, dataset, "txt")

    try:
        head = S3.head_object(Bucket=RAW_BUCKET, Key=key)
        if head.get("Metadata", {}).get("sha256") == sha:
            pass
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code not in ("404", "NoSuchKey", "NotFound", "403", "AccessDenied"):
            raise

    S3.put_object(
        Bucket=RAW_BUCKET,
        Key=key,
        Body=content,
        ContentType="text/plain",
        Metadata={"source_url": url, "sha256": sha, "dataset": dataset},
    )

    try:
        text_preview = content.decode("utf-8", errors="replace")
    except Exception:
        text_preview = ""

    items = [{"dataset": dataset, "preview": text_preview, "key": key, "url": url}]
    summary = summarize_with_bedrock(day, items)

    html = f"""
        <div style="font-family:Arial,Helvetica,sans-serif; line-height:1.4;">
            <h2>Daily AER Summary – {day:%Y-%m-%d}</h2>
            <p><strong>Dataset:</strong> {dataset}</p>
            <pre style="white-space:pre-wrap">{summary}</pre>
            <p style="margin-top:16px;">Source file stored temporarily in S3: {key}</p>
        </div>
    """

    # SNS email delivers text-only; send a text version
    text_message = f"Daily AER Summary – {day:%Y-%m-%d}\nDataset: {dataset}\n\n{summary}\n\nSource (temporary S3 key): {key}"
    publish_sns(subject=f"AER {dataset} summary – {day:%Y-%m-%d}", message=text_message)

    S3.delete_object(Bucket=RAW_BUCKET, Key=key)

    return {"dataset": dataset, "date": f"{day:%Y-%m-%d}", "status": "emailed_and_deleted", "url": url}


