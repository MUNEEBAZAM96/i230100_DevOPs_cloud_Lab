#!/usr/bin/env bash
# Collect the lab checks into evidence.txt. A failed command is recorded and the script continues.
if [[ "$#" -ne 3 ]]; then
  echo "Usage: ./collect-evidence.sh <bucket-name> <ec2-address> <lambda-address>"
  exit 1
fi

BUCKET="$1"
EC2_URL="$2"
LAMBDA_URL="$3"

REGION="us-east-1"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""

EC2_ROLE="cv-ec2-role-i230100"
LAMBDA_ROLE="cv-lambda-role-i230100"
EC2_POLICY="cv-ec2-s3-read"
LAMBDA_POLICY="cv-lambda-s3-read"
INSTANCE_NAME="cv-ec2-i230100"
LOG_GROUP="/aws/lambda/cv-func-i230100"

case "$EC2_URL" in
  http://*|https://*) ;;
  *) EC2_URL="http://${EC2_URL}" ;;
esac
case "$LAMBDA_URL" in
  http://*|https://*) ;;
  *) LAMBDA_URL="https://${LAMBDA_URL}" ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${ROOT}/evidence.txt"
: > "$OUT"

section() {
  printf '== %s ==\n' "$1" >> "$OUT"
}

run_into() {
  local output ec
  output="$("$@" 2>&1)" && ec=0 || ec=$?
  if [[ "$ec" -eq 0 ]]; then
    printf '%s\n' "$output" >> "$OUT"
  else
    printf 'COMMAND FAILED (exit %s): %s\n%s\n' "$ec" "$*" "$output" >> "$OUT"
  fi
}

section "caller"
run_into aws sts get-caller-identity --region "$REGION" --output json
printf '\n' >> "$OUT"

section "public-access"
run_into aws s3api get-public-access-block --region "$REGION" --bucket "$BUCKET" --output json
printf '\n' >> "$OUT"

section "versioning"
run_into aws s3api get-bucket-versioning --region "$REGION" --bucket "$BUCKET" --output json
printf '\n' >> "$OUT"

section "objects"
run_into aws s3 ls "s3://${BUCKET}/site/" --region "$REGION"
printf '\n' >> "$OUT"

section "ec2-policy"
run_into aws iam get-role-policy --region "$REGION" --role-name "$EC2_ROLE" --policy-name "$EC2_POLICY" --output json
printf '\n' >> "$OUT"

section "lambda-policy"
{
  echo "-- attached managed policies --"
  attached="$(aws iam list-attached-role-policies --region "$REGION" --role-name "$LAMBDA_ROLE" --output json 2>&1)" && aec=0 || aec=$?
  if [[ "$aec" -eq 0 ]]; then
    printf '%s\n' "$attached"
  else
    printf 'COMMAND FAILED (exit %s): aws iam list-attached-role-policies --role-name %s\n%s\n' "$aec" "$LAMBDA_ROLE" "$attached"
  fi
  echo
  echo "-- inline policy --"
  inline="$(aws iam get-role-policy --region "$REGION" --role-name "$LAMBDA_ROLE" --policy-name "$LAMBDA_POLICY" --output json 2>&1)" && iec=0 || iec=$?
  if [[ "$iec" -eq 0 ]]; then
    printf '%s\n' "$inline"
  else
    printf 'COMMAND FAILED (exit %s): aws iam get-role-policy --role-name %s --policy-name %s\n%s\n' "$iec" "$LAMBDA_ROLE" "$LAMBDA_POLICY" "$inline"
  fi
} >> "$OUT"
printf '\n' >> "$OUT"

section "security-group"
{
  instance_json="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].SecurityGroups[].GroupId" --output text 2>&1)" && sec=0 || sec=$?
  if [[ "$sec" -ne 0 || -z "${instance_json// }" || "$instance_json" == "None" ]]; then
    printf 'COMMAND FAILED (exit %s): aws ec2 describe-instances (security group lookup)\n%s\n' "$sec" "$instance_json"
  else
    for group_id in $instance_json; do
      echo "GroupId ${group_id}"
      desc="$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$group_id" --output json 2>&1)" && dec=0 || dec=$?
      if [[ "$dec" -eq 0 ]]; then
        printf '%s\n' "$desc"
      else
        printf 'COMMAND FAILED (exit %s): aws ec2 describe-security-groups --group-ids %s\n%s\n' "$dec" "$group_id" "$desc"
      fi
    done
    if [[ -z "${instance_json// }" ]]; then
      echo "COMMAND FAILED: no security group found for ${INSTANCE_NAME}"
    fi
  fi
} >> "$OUT"
printf '\n' >> "$OUT"

section "instance"
run_into aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].{InstanceId:InstanceId,InstanceType:InstanceType,HttpTokens:MetadataOptions.HttpTokens,HttpEndpoint:MetadataOptions.HttpEndpoint,IamInstanceProfile:IamInstanceProfile.Arn,PublicIpAddress:PublicIpAddress}" \
  --output json
printf '\n' >> "$OUT"

section "endpoints"
{
  probe() {
    local label="$1"
    local url="$2"
    local body http_line ec
    body="$(mktemp)"
    echo "${label} ${url}"
    http_line="$(curl -sS --max-time 30 -o "$body" -w "http_code=%{http_code} content_type=%{content_type}" "$url" 2>"${body}.err")" && ec=0 || ec=$?
    if [[ "$ec" -eq 0 ]]; then
      printf '%s\n' "$http_line"
      echo "body_head:"
      head -c 300 "$body"
      printf '\n'
    else
      printf 'COMMAND FAILED (exit %s): curl -sS -o BODY -w http_code=%%{http_code} content_type=%%{content_type} %s\n' "$ec" "$url"
      cat "${body}.err"
      printf '\n'
    fi
    rm -f "$body" "${body}.err"
    echo
  }
  probe "EC2" "${EC2_URL%/}/"
  probe "Lambda" "${LAMBDA_URL%/}/"
  probe "S3" "https://${BUCKET}.s3.${REGION}.amazonaws.com/site/index.html"
} >> "$OUT"

section "lambda-logs"
{
  logs="$(aws logs tail "$LOG_GROUP" --region "$REGION" --since 6h --format short --no-follow 2>&1)" && lec=0 || lec=$?
  if [[ "$lec" -eq 0 ]]; then
    printf '%s\n' "$logs" | tail -n 40
  else
    printf 'COMMAND FAILED (exit %s): aws logs tail %s --since 6h --format short --no-follow\n%s\n' "$lec" "$LOG_GROUP" "$logs"
  fi
} >> "$OUT"
printf '\n' >> "$OUT"

section "log-retention"
run_into aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$LOG_GROUP" --output json
printf '\n' >> "$OUT"

echo "DONE"
