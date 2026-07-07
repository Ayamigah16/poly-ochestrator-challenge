#!/usr/bin/env bash
# One-time setup: create the S3 bucket and DynamoDB table that store
# Terraform remote state. Run ONCE before your first `terraform init`.
# Safe to re-run — every AWS call is idempotent.
#
# Usage:
#   ./scripts/terraform-bootstrap.sh
#   ./scripts/terraform-bootstrap.sh --region eu-west-1 --prefix my-project

source "$(dirname "$0")/lib.sh"

AWS_REGION="eu-west-1"
PREFIX="poly-orchestrator"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2 ;;
    --prefix) PREFIX="$2";     shift 2 ;;
    --help|-h)
      grep '^#' "$0" | head -10 | sed 's/^# \?//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

STATE_BUCKET="${PREFIX}-tf-state"
LOCK_TABLE="${PREFIX}-tf-lock"

require aws terraform

# ── AWS identity check ─────────────────────────────────────────────────────────
step "AWS identity"
CALLER=$(aws sts get-caller-identity --output json)
info "Account: $(echo "$CALLER" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["Account"])')"
info "ARN:     $(echo "$CALLER" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["Arn"])')"
info "Region:  $AWS_REGION"
echo ""
confirm "Bootstrap Terraform remote state in the account above?"

# ── S3 bucket ─────────────────────────────────────────────────────────────────
step "S3 state bucket: s3://$STATE_BUCKET"

if aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
  info "Bucket already exists"
else
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$STATE_BUCKET" \
      --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$STATE_BUCKET" \
      --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
  success "Bucket created"
fi

# Enable versioning — allows state recovery if a partial apply corrupts it
aws s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled
success "Versioning enabled"

# Enable server-side encryption at rest
aws s3api put-bucket-encryption \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
success "Server-side encryption (AES256) enabled"

# Block all public access
aws s3api put-public-access-block \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
success "Public access blocked"

# ── DynamoDB lock table ────────────────────────────────────────────────────────
step "DynamoDB lock table: $LOCK_TABLE"

if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$AWS_REGION" &>/dev/null; then
  info "Table already exists"
else
  aws dynamodb create-table \
    --table-name "$LOCK_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"
  success "DynamoDB table created"

  info "Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists \
    --table-name "$LOCK_TABLE" \
    --region "$AWS_REGION"
  success "Table is ACTIVE"
fi

# ── Print backend config ───────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Bootstrap complete!${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  Ensure your infra/terraform/main.tf backend block matches:"
echo ""
echo -e "  ${CYAN}terraform {${RESET}"
echo -e "    ${CYAN}backend \"s3\" {${RESET}"
echo -e "      ${CYAN}bucket         = \"${STATE_BUCKET}\"${RESET}"
echo -e "      ${CYAN}key            = \"${PREFIX}/terraform.tfstate\"${RESET}"
echo -e "      ${CYAN}region         = \"${AWS_REGION}\"${RESET}"
echo -e "      ${CYAN}encrypt        = true${RESET}"
echo -e "      ${CYAN}dynamodb_table = \"${LOCK_TABLE}\"${RESET}"
echo -e "    ${CYAN}}${RESET}"
echo -e "  ${CYAN}}${RESET}"
echo ""
echo "  Then run:  ./scripts/terraform-apply.sh --env staging"
