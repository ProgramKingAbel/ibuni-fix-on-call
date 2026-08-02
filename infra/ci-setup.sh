#!/usr/bin/env bash
# One-time CI identity setup: a GitHub OIDC provider and a deploy role.
#
#   AWS_PROFILE=<profile> ./infra/ci-setup.sh
#
# GitHub Actions assumes the role via OIDC, so there are NO long-lived AWS access
# keys anywhere — nothing to leak, nothing to rotate, and nothing to store in
# repository secrets except the role ARN (which is not a credential).
#
# The role is scoped to exactly what deploy.sh touches. It deliberately cannot
# create or delete infrastructure — provisioning stays a human action.

source "$(dirname "$0")/env.sh"

REPO="${GH_REPO:-ProgramKingAbel/ibuni-fix-on-call}"
CI_ROLE="foc-doc-ci-deploy"
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"

echo "account : $ACCOUNT"
echo "repo    : $REPO"
echo

# ------------------------------------------------------------ OIDC provider ---
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "==> GitHub OIDC provider already exists"
else
  echo "==> creating GitHub OIDC provider"
  # No --thumbprint-list: IAM now validates GitHub's certificate chain itself,
  # so a pinned thumbprint is both unnecessary and a future breakage.
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com >/dev/null
fi

# -------------------------------------------------------------------- role ----
# `sub` is restricted to this repo AND to the deploy job's environment. Without a
# condition beyond the repo, anyone able to open a PR from a fork could assume it.
#
# GOTCHA: the subject depends on how the job is scoped. A job with
# `environment: production` gets
#     repo:<owner>/<repo>:environment:production
# NOT
#     repo:<owner>/<repo>:ref:refs/heads/main
# Getting this wrong fails with "Not authorized to perform
# sts:AssumeRoleWithWebIdentity", which reads like a missing permission rather
# than a mismatched condition. Keep this in step with .github/workflows/deploy.yml.
cat > "$TMPD/ci-trust.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:${REPO}:environment:production"
      }
    }
  }]
}
JSON

if aws iam get-role --role-name "$CI_ROLE" >/dev/null 2>&1; then
  echo "==> role $CI_ROLE exists — refreshing trust policy"
  aws iam update-assume-role-policy --role-name "$CI_ROLE" \
    --policy-document "$(filearg "$TMPD/ci-trust.json")"
else
  echo "==> creating role $CI_ROLE"
  aws iam create-role --role-name "$CI_ROLE" \
    --description "GitHub Actions deploy role for the Fix On Call platform overview" \
    --assume-role-policy-document "$(filearg "$TMPD/ci-trust.json")" >/dev/null
fi

# ------------------------------------------------------------------ policy ----
# Deploy-only. No iam:*, no *:Create* for infrastructure, no dynamodb:DeleteTable.
# A compromised workflow can ship a bad page — it cannot take the account.
cat > "$TMPD/ci-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "SiteObjects", "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject","s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${BUCKET}","arn:aws:s3:::${BUCKET}/*"] },
    { "Sid": "LambdaCode", "Effect": "Allow",
      "Action": ["lambda:UpdateFunctionCode","lambda:GetFunction",
                 "lambda:GetFunctionConfiguration","lambda:GetFunctionUrlConfig"],
      "Resource": "arn:aws:lambda:${AWS_REGION}:${ACCOUNT}:function:${FUNC}" },
    { "Sid": "EdgeFunction", "Effect": "Allow",
      "Action": ["cloudfront:DescribeFunction","cloudfront:UpdateFunction",
                 "cloudfront:PublishFunction","cloudfront:TestFunction",
                 "cloudfront:GetFunction"],
      "Resource": "arn:aws:cloudfront::${ACCOUNT}:function/${CFFUNC}" },
    { "Sid": "Invalidate", "Effect": "Allow",
      "Action": ["cloudfront:CreateInvalidation","cloudfront:GetInvalidation"],
      "Resource": "arn:aws:cloudfront::${ACCOUNT}:distribution/*" },
    { "Sid": "ListForLookups", "Effect": "Allow",
      "Action": ["cloudfront:ListDistributions"],
      "Resource": "*" }
  ]
}
JSON
aws iam put-role-policy --role-name "$CI_ROLE" --policy-name deploy \
  --policy-document "$(filearg "$TMPD/ci-policy.json")"

ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${CI_ROLE}"
echo
echo "CI role ready: $ROLE_ARN"
echo
echo "Add these to the GitHub repository (Settings → Secrets and variables → Actions):"
echo
echo "  Variable  AWS_ROLE_ARN   = $ROLE_ARN"
echo "  Secret    SESSION_SECRET = <the 'current=' line from infra/.session-secret>"
echo "  Secret    SESSION_PREV   = <the 'prev=' line, may be empty>"
echo
echo "The session secret is needed because CI rebuilds the edge function, which"
echo "carries the signing keys. It is the ONLY secret CI needs."
echo
echo "  gh variable set AWS_ROLE_ARN --body '$ROLE_ARN'"
echo "  gh secret   set SESSION_SECRET --body \"\$(sed -n 's/^current=//p' infra/.session-secret)\""
echo "  gh secret   set SESSION_PREV   --body \"\$(sed -n 's/^prev=//p'    infra/.session-secret)\""
