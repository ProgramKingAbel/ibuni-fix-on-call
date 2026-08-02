#!/usr/bin/env bash
# One-time resource creation, in dependency order. Idempotent — safe to re-run
# after a failure; each step checks for the resource before creating it.
#
#   AWS_PROFILE=<profile> ./infra/provision.sh
#
# SES is deliberately NOT automated (step 0): it needs DNS records published and
# a production-access request, which are wall-clock items you should start first.
# Everything else takes minutes.

source "$(dirname "$0")/env.sh"
load_secrets_optional() { [ -f "$SECRET_FILE" ] && load_secrets || true; }

echo "account : $ACCOUNT"
echo "region  : $AWS_REGION"
echo "bucket  : $BUCKET"
echo

# ---------------------------------------------------------------- 1. secrets --
if [ ! -f "$SECRET_FILE" ]; then
  echo "==> generating session secrets"
  { echo "current=$(openssl rand -base64 48 | tr -d '\n')"
    echo "prev="
    echo "pepper=$(openssl rand -base64 48 | tr -d '\n')"
  } > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE" 2>/dev/null || true
  echo "    wrote $SECRET_FILE (gitignored)"
else
  echo "==> secrets already present"
fi
load_secrets

# --------------------------------------------------------------- 2. dynamodb --
if aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  echo "==> table $TABLE exists"
else
  echo "==> creating table $TABLE"
  aws dynamodb create-table --table-name "$TABLE" \
    --attribute-definitions AttributeName=anchor_id,AttributeType=S AttributeName=sort_key,AttributeType=S \
    --key-schema AttributeName=anchor_id,KeyType=HASH AttributeName=sort_key,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE"
  aws dynamodb update-time-to-live --table-name "$TABLE" \
    --time-to-live-specification 'Enabled=true,AttributeName=expires_at' >/dev/null
  echo "    created, TTL enabled on expires_at"
fi

# ------------------------------------------------------------------- 3. IAM ---
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  echo "==> role $ROLE exists"
else
  echo "==> creating role $ROLE"
  nopath aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  nopath aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  sleep 10   # IAM propagation, or the Lambda create below fails
fi

echo "==> putting inline policy"
cat > "$TMPD/foc-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "Table", "Effect": "Allow",
      "Action": ["dynamodb:Query","dynamodb:GetItem","dynamodb:PutItem",
                 "dynamodb:UpdateItem","dynamodb:DeleteItem","dynamodb:Scan",
                 "dynamodb:BatchWriteItem"],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT}:table/${TABLE}" },
    { "Sid": "SendOtpOnly", "Effect": "Allow",
      "Action": ["ses:SendEmail"],
      "Resource": "*",
      "Condition": { "StringEquals": { "ses:FromAddress": "${FROM_ADDR}" } } }
  ]
}
JSON
aws iam put-role-policy --role-name "$ROLE" --policy-name foc-doc-access \
  --policy-document "$(filearg "$TMPD/foc-policy.json")"

# ---------------------------------------------------------------- 4. lambda ---
echo "==> packaging lambda"
# `zip` is not installed on this machine — use PowerShell's Compress-Archive.
rm -f "$ROOT/infra/lambda/function.zip"
powershell.exe -NoProfile -Command \
  "Compress-Archive -Path '$(cygpath -w "$ROOT/infra/lambda/index.mjs")' -DestinationPath '$(cygpath -w "$ROOT/infra/lambda/function.zip")' -Force" >/dev/null

ENVVARS="Variables={TABLE=$TABLE,ISS=foc-doc,TTL_DAYS=7,FROM_ADDR=$FROM_ADDR,SESSION_SECRET=$SESSION_CURRENT,SESSION_SECRET_PREV=$SESSION_PREV,OTP_PEPPER=$OTP_PEPPER}"

if aws lambda get-function --function-name "$FUNC" >/dev/null 2>&1; then
  echo "==> lambda $FUNC exists — updating code + config"
  aws lambda update-function-code --function-name "$FUNC" \
    --zip-file "$(filebarg "$ROOT/infra/lambda/function.zip")" >/dev/null
  aws lambda wait function-updated --function-name "$FUNC"
  nopath aws lambda update-function-configuration --function-name "$FUNC" --environment "$ENVVARS" >/dev/null
else
  echo "==> creating lambda $FUNC"
  nopath aws lambda create-function --function-name "$FUNC" --runtime nodejs20.x \
    --role "arn:aws:iam::${ACCOUNT}:role/${ROLE}" --handler index.handler \
    --zip-file "$(filebarg "$ROOT/infra/lambda/function.zip")" \
    --timeout 10 --memory-size 256 --environment "$ENVVARS" >/dev/null
  aws lambda wait function-active --function-name "$FUNC"
fi

# --- API origin: API Gateway HTTP API -----------------------------------
# NOT a Lambda Function URL. Public Function URLs are blocked at the account
# level here (403 regardless of AuthType=NONE and a correct resource policy),
# and that is not something the CLI can query or change. HTTP API payload
# format 2.0 gives the handler an identical event shape, so nothing in the
# Lambda changes.
APIID="$(api_id)"
if [ "$APIID" = "None" ] || [ -z "$APIID" ]; then
  echo "==> creating HTTP API $APIGW"
  APIID="$(aws apigatewayv2 create-api --name "$APIGW" --protocol-type HTTP     --target "arn:aws:lambda:${AWS_REGION}:${ACCOUNT}:function:${FUNC}"     --query ApiId --output text)"
else
  echo "==> HTTP API exists: $APIID"
fi
aws lambda add-permission --function-name "$FUNC" --statement-id apigw-invoke   --action lambda:InvokeFunction --principal apigateway.amazonaws.com   --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT}:${APIID}/*/*" >/dev/null 2>&1 || true
FURL="$(api_endpoint)"
echo "    api endpoint: $FURL"

# -------------------------------------------------------------------- 5. S3 ---
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "==> bucket $BUCKET exists"
else
  echo "==> creating bucket $BUCKET"
  aws s3api create-bucket --bucket "$BUCKET" >/dev/null    # us-east-1 takes no LocationConstraint
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
fi

# ------------------------------------------------- 6. CloudFront Function -----
echo "==> building dist/"
node "$ROOT/infra/build.mjs" "$ROOT" "$SESSION_CURRENT" "$SESSION_PREV"

if aws cloudfront describe-function --name "$CFFUNC" >/dev/null 2>&1; then
  echo "==> cloudfront function $CFFUNC exists (deploy.sh updates it)"
else
  echo "==> creating cloudfront function $CFFUNC"
  aws cloudfront create-function --name "$CFFUNC" \
    --function-config 'Comment="Fix On Call session gate",Runtime=cloudfront-js-2.0' \
    --function-code "$(filebarg "$ROOT/dist/cf-session-gate.js")" >/dev/null
  ETAG="$(aws cloudfront describe-function --name "$CFFUNC" --query ETag --output text)"
  aws cloudfront publish-function --name "$CFFUNC" --if-match "$ETAG" >/dev/null
  echo "    published"
fi
CFARN="$(aws cloudfront describe-function --name "$CFFUNC" --stage LIVE --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text)"

# ------------------------------------------------------------------- 7. OAC ---
OACID="$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='foc-doc-s3'].Id | [0]" --output text 2>/dev/null)"
if [ "$OACID" = "None" ] || [ -z "$OACID" ]; then
  echo "==> creating OAC"
  OACID="$(aws cloudfront create-origin-access-control --origin-access-control-config \
    'Name=foc-doc-s3,OriginAccessControlOriginType=s3,SigningBehavior=always,SigningProtocol=sigv4' \
    --query 'OriginAccessControl.Id' --output text)"
fi
echo "    oac: $OACID"

# ---------------------------------------------------------- 8. distribution ---
DIST="$(dist_id)"
if [ "$DIST" != "None" ] && [ -n "$DIST" ]; then
  echo "==> distribution exists: $DIST"
else
  echo "==> creating distribution"
  FHOST="$(echo "$FURL" | sed -e 's#^https://##' -e 's#/$##')"

  # Managed policy ids, resolved live rather than trusted from memory.
  CACHE_DISABLED="$(aws cloudfront list-cache-policies --type managed \
    --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='Managed-CachingDisabled'].CachePolicy.Id | [0]" --output text)"
  CACHE_OPTIMIZED="$(aws cloudfront list-cache-policies --type managed \
    --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='Managed-CachingOptimized'].CachePolicy.Id | [0]" --output text)"
  # AllViewerExceptHostHeader is REQUIRED for a Lambda Function URL origin —
  # forwarding the viewer Host header makes the Function URL return 403.
  ORP_ALLVIEWER="$(aws cloudfront list-origin-request-policies --type managed \
    --query "OriginRequestPolicyList.Items[?OriginRequestPolicy.OriginRequestPolicyConfig.Name=='Managed-AllViewerExceptHostHeader'].OriginRequestPolicy.Id | [0]" --output text)"

  cat > "$TMPD/foc-dist.json" <<JSON
{
  "CallerReference": "foc-doc-$(date +%s)",
  "Comment": "Fix On Call — Platform Overview",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "HttpVersion": "http2and3",
  "PriceClass": "PriceClass_All",
  "Origins": { "Quantity": 2, "Items": [
    { "Id": "s3-origin",
      "DomainName": "${BUCKET}.s3.${AWS_REGION}.amazonaws.com",
      "OriginAccessControlId": "${OACID}",
      "S3OriginConfig": { "OriginAccessIdentity": "" } },
    { "Id": "lambda-origin",
      "DomainName": "${FHOST}",
      "CustomOriginConfig": {
        "HTTPPort": 80, "HTTPSPort": 443,
        "OriginProtocolPolicy": "https-only",
        "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] } } }
  ]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": { "Quantity": 2, "Items": ["GET","HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] } },
    "CachePolicyId": "${CACHE_DISABLED}",
    "Compress": true,
    "FunctionAssociations": { "Quantity": 1, "Items": [
      { "EventType": "viewer-request", "FunctionARN": "${CFARN}" } ] }
  },
  "CacheBehaviors": { "Quantity": 2, "Items": [
    { "PathPattern": "/api/*",
      "TargetOriginId": "lambda-origin",
      "ViewerProtocolPolicy": "https-only",
      "AllowedMethods": { "Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
        "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] } },
      "CachePolicyId": "${CACHE_DISABLED}",
      "OriginRequestPolicyId": "${ORP_ALLVIEWER}",
      "Compress": true,
      "FunctionAssociations": { "Quantity": 0 } },
    { "PathPattern": "/login*",
      "TargetOriginId": "s3-origin",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": { "Quantity": 2, "Items": ["GET","HEAD"],
        "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] } },
      "CachePolicyId": "${CACHE_OPTIMIZED}",
      "Compress": true,
      "FunctionAssociations": { "Quantity": 0 } }
  ]}
}
JSON
  DIST="$(aws cloudfront create-distribution --distribution-config "$(filearg "$TMPD/foc-dist.json")" \
    --query 'Distribution.Id' --output text)"
  
  echo "    created: $DIST"
fi

# ------------------------------------------------------- 9. bucket policy -----
# Must come after the distribution — it needs the distribution ARN.
echo "==> bucket policy (CloudFront-only read)"
cat > "$TMPD/foc-bucket.json" <<JSON
{ "Version": "2012-10-17", "Statement": [
  { "Sid": "AllowCloudFrontOnly", "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET}/*",
    "Condition": { "StringEquals": {
      "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT}:distribution/${DIST}" } } }
]}
JSON
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(filearg "$TMPD/foc-bucket.json")"


echo
echo "provisioned. distribution $DIST"
echo "  domain : https://$(dist_domain)"
echo
echo "next:"
echo "  1. SES — verify $FROM_DOMAIN (DKIM + custom MAIL FROM + DMARC), request production access,"
echo "     and verify recipient addresses in parallel."
echo "  2. ./infra/members.sh add <email> \"<name>\" \"<role>\"   (once per person)"
echo "  3. ./infra/deploy.sh"
echo "  (the distribution takes ~10 min to finish deploying before it serves)"
