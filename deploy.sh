#!/usr/bin/env bash
# Create the private bucket, both roles, the EC2 site, and the Lambda site.
# Region for every resource in this lab: us-east-1.
set -euo pipefail

REGION="us-east-1"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""

ROLL="i230100"
BUCKET="cv-${ROLL}"
EC2_NAME="cv-ec2-${ROLL}"
EC2_ROLE="cv-ec2-role-${ROLL}"
LAMBDA_NAME="cv-func-${ROLL}"
LAMBDA_ROLE="cv-lambda-role-${ROLL}"
EC2_POLICY="cv-ec2-s3-read"
LAMBDA_POLICY="cv-lambda-s3-read"
SG_NAME="cv-sg-${ROLL}"
BUDGET_NAME="cv-lab-${ROLL}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if ! command -v aws >/dev/null 2>&1; then
  echo "The AWS CLI is not installed."
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Account ${ACCOUNT_ID} in ${REGION}"

python3 - << 'PY'
import json, pathlib, sys
root = pathlib.Path("iam")
for path in root.glob("*.json"):
    data = json.loads(path.read_text())
    blobs = []
    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("Action", "Resource") or key.endswith("Action") or key.endswith("Resource"):
                    blobs.append(value)
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)
    walk(data)
    flat = []
    def flatten(value):
        if isinstance(value, list):
            for item in value:
                flatten(item)
        else:
            flat.append(str(value))
    for value in blobs:
        flatten(value)
    for item in flat:
        if item == "*" or item.endswith(":*") or "*" in item:
            sys.exit(f"{path} has a wildcard: {item}")
print("IAM JSON has no wildcard action or resource")
PY

if aws budgets describe-budget --region us-east-1 --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" >/dev/null 2>&1; then
  echo "Budget ${BUDGET_NAME} already exists"
else
  echo "Creating budget ${BUDGET_NAME}"
  aws budgets create-budget --region us-east-1 --account-id "$ACCOUNT_ID" \
    --budget "{\"BudgetName\":\"${BUDGET_NAME}\",\"BudgetLimit\":{\"Amount\":\"5\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}" \
    --notifications-with-subscribers "[{\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":80,\"ThresholdType\":\"PERCENTAGE\",\"NotificationState\":\"ALARM\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"muneebazam96@gmail.com\"}]}]"
fi

if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "Bucket ${BUCKET} already exists and is reachable"
else
  echo "Creating bucket ${BUCKET}"
  set +e
  create_err="$(aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" 2>&1)"
  create_ec=$?
  set -e
  if [[ "$create_ec" -ne 0 ]]; then
    if grep -q "BucketAlreadyOwnedByYou" <<< "$create_err"; then
      echo "Bucket already owned by this account"
    elif grep -q "BucketAlreadyExists" <<< "$create_err"; then
      echo "Bucket name ${BUCKET} is taken by another account. Add digits and update every name before continuing."
      printf '%s\n' "$create_err"
      exit 1
    else
      printf '%s\n' "$create_err"
      exit 1
    fi
  fi
fi

aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=Owner,Value=${ROLL}},{Key=Course,Value=cloud}]"
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api delete-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 || true

aws s3 cp site/index.html "s3://${BUCKET}/site/index.html" --content-type "text/html; charset=utf-8"
aws s3 cp site/style.css "s3://${BUCKET}/site/style.css" --content-type "text/css; charset=utf-8"
aws s3 cp site/cv.pdf "s3://${BUCKET}/site/cv.pdf" --content-type "application/pdf"

if aws iam get-role --role-name "$EC2_ROLE" >/dev/null 2>&1; then
  echo "Role ${EC2_ROLE} already exists"
else
  aws iam create-role --role-name "$EC2_ROLE" \
    --assume-role-policy-document "file://${ROOT}/iam/ec2-trust-policy.json" \
    --description "Read the CV site for the EC2 web server" \
    --tags Key=Owner,Value="$ROLL" Key=Course,Value=cloud
fi
aws iam put-role-policy --role-name "$EC2_ROLE" --policy-name "$EC2_POLICY" \
  --policy-document "file://${ROOT}/iam/ec2-permission-policy.json"
if aws iam get-instance-profile --instance-profile-name "$EC2_ROLE" >/dev/null 2>&1; then
  echo "Instance profile ${EC2_ROLE} already exists"
else
  aws iam create-instance-profile --instance-profile-name "$EC2_ROLE"
  aws iam add-role-to-instance-profile --instance-profile-name "$EC2_ROLE" --role-name "$EC2_ROLE"
  sleep 10
fi

if aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  echo "Role ${LAMBDA_ROLE} already exists"
else
  aws iam create-role --role-name "$LAMBDA_ROLE" \
    --assume-role-policy-document "file://${ROOT}/iam/lambda-trust-policy.json" \
    --description "Read the CV site for the Lambda function" \
    --tags Key=Owner,Value="$ROLL" Key=Course,Value=cloud
fi
aws iam attach-role-policy --role-name "$LAMBDA_ROLE" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name "$LAMBDA_POLICY" \
  --policy-document "file://${ROOT}/iam/lambda-permission-policy.json"
LAMBDA_ROLE_ARN="$(aws iam get-role --role-name "$LAMBDA_ROLE" --query Role.Arn --output text)"
sleep 12

aws logs create-log-group --log-group-name "/aws/lambda/${LAMBDA_NAME}" >/dev/null 2>&1 || true
aws logs put-retention-policy --log-group-name "/aws/lambda/${LAMBDA_NAME}" --retention-in-days 7

rm -f "${ROOT}/lambda/function.zip"
( cd "${ROOT}/lambda" && zip -q function.zip lambda_function.py )

RUNTIME=""
if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  RUNTIME="$(aws lambda get-function-configuration --function-name "$LAMBDA_NAME" --query Runtime --output text)"
else
  for candidate in python3.14 python3.13 python3.12; do
    echo "Checking Lambda runtime ${candidate}"
    created=0
    for _try in 1 2 3 4 5 6; do
      set +e
      probe="$(aws lambda create-function --function-name "$LAMBDA_NAME" \
        --runtime "$candidate" \
        --role "$LAMBDA_ROLE_ARN" \
        --handler lambda_function.lambda_handler \
        --zip-file "fileb://${ROOT}/lambda/function.zip" \
        --timeout 10 --memory-size 128 --architectures arm64 \
        --environment "Variables={BUCKET=${BUCKET},PREFIX=site}" \
        --logging-config "LogFormat=Text,LogGroup=/aws/lambda/${LAMBDA_NAME}" \
        --tags "Owner=${ROLL},Course=cloud" 2>&1)"
      probe_ec=$?
      set -e
      if [[ "$probe_ec" -eq 0 ]]; then
        created=1
        break
      fi
      if grep -qi "cannot be assumed\|not ready\|assume" <<< "$probe"; then
        sleep 8
        continue
      fi
      break
    done
    if [[ "$created" -eq 1 ]]; then
      RUNTIME="$candidate"
      break
    fi
    if grep -qi "runtime" <<< "$probe"; then
      echo "${candidate} is not offered here"
      continue
    fi
    printf '%s\n' "$probe"
    exit 1
  done
fi

if [[ -z "$RUNTIME" ]]; then
  echo "No Python Lambda runtime could be created."
  exit 1
fi
echo "Lambda runtime ${RUNTIME}"

if ! aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  echo "Function was not created."
  exit 1
fi
aws lambda wait function-active --function-name "$LAMBDA_NAME"
aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file "fileb://${ROOT}/lambda/function.zip" >/dev/null
aws lambda wait function-updated --function-name "$LAMBDA_NAME"
aws lambda update-function-configuration --function-name "$LAMBDA_NAME" \
  --runtime "$RUNTIME" --timeout 10 --memory-size 128 \
  --environment "Variables={BUCKET=${BUCKET},PREFIX=site}" \
  --logging-config "LogFormat=Text,LogGroup=/aws/lambda/${LAMBDA_NAME}" >/dev/null
aws lambda wait function-updated --function-name "$LAMBDA_NAME"
LAMBDA_ARN="$(aws lambda get-function --function-name "$LAMBDA_NAME" --query Configuration.FunctionArn --output text)"
aws lambda tag-resource --resource "$LAMBDA_ARN" --tags "Owner=${ROLL},Course=cloud"
rm -f "${ROOT}/lambda/function.zip"

if aws lambda get-function-url-config --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  LAMBDA_URL="$(aws lambda get-function-url-config --function-name "$LAMBDA_NAME" --query FunctionUrl --output text)"
else
  LAMBDA_URL="$(aws lambda create-function-url-config --function-name "$LAMBDA_NAME" --auth-type NONE --query FunctionUrl --output text)"
fi
aws lambda add-permission --function-name "$LAMBDA_NAME" \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE >/dev/null 2>&1 || true
if aws lambda add-permission help 2>&1 | grep -q invoked-via-function-url; then
  aws lambda add-permission --function-name "$LAMBDA_NAME" \
    --statement-id FunctionURLInvokeAllowPublicAccess \
    --action lambda:InvokeFunction \
    --principal "*" \
    --invoked-via-function-url >/dev/null 2>&1 || true
fi

VPC_ID="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query "Vpcs[0].VpcId" --output text)"
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "This account has no default VPC in ${REGION}. Create one before launching the instance. Do not add a NAT gateway."
  exit 1
fi
SUBNET_ID="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query "sort_by(Subnets, &AvailabilityZone)[0].SubnetId" --output text)"

SG_ID="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$SG_NAME" \
  --query "SecurityGroups[0].GroupId" --output text)"
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  SG_ID="$(aws ec2 create-security-group --group-name "$SG_NAME" --description "HTTP for the CV site" --vpc-id "$VPC_ID" --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP}]"
  MY_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP}/32,Description=SSH from my address}]"
fi

INSTANCE_ID="$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values="$EC2_NAME" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query "Reservations[].Instances[].InstanceId | [0]" --output text)"
if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  state="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].State.Name" --output text)"
  echo "Instance ${INSTANCE_ID} is ${state}"
  if [[ "$state" == "stopped" ]]; then
    aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
  fi
else
  AMI_ID="$(aws ec2 describe-images --owners amazon \
    --filters Name=name,Values='al2023-ami-2023*-x86_64' Name=state,Values=available Name=architecture,Values=x86_64 \
    --query "reverse(sort_by(Images[?contains(Name, 'kernel') && !contains(Name, 'minimal') && !contains(Name, 'ecs')], &CreationDate))[0].ImageId" \
    --output text)"
  echo "Launching ${EC2_NAME} from ${AMI_ID}"
  INSTANCE_ID="$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type t3.micro \
    --iam-instance-profile "Name=${EC2_ROLE}" \
    --network-interfaces "DeviceIndex=0,AssociatePublicIpAddress=true,SubnetId=${SUBNET_ID},Groups=${SG_ID}" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2" \
    --credit-specification "CpuCredits=standard" \
    --user-data "file://${ROOT}/ec2/user-data.sh" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${EC2_NAME}},{Key=Owner,Value=${ROLL}},{Key=Course,Value=cloud}]" \
    --count 1 \
    --query "Instances[0].InstanceId" --output text)"
fi

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)"
echo "EC2 http://${PUBLIC_IP}/"
echo "Lambda ${LAMBDA_URL}"
printf 'EC2_URL=http://%s/\nLAMBDA_URL=%s\nBUCKET=%s\nINSTANCE_ID=%s\n' "$PUBLIC_IP" "$LAMBDA_URL" "$BUCKET" "$INSTANCE_ID" > "${ROOT}/deploy-outputs.txt"
