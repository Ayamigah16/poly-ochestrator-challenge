#!/usr/bin/env bash
# Plan and apply Terraform infrastructure changes with safety guardrails.
# Always shows a plan first; requires explicit confirmation before apply.
#
# Usage:
#   ./scripts/terraform-apply.sh --env staging --platform eks
#   ./scripts/terraform-apply.sh --env staging --platform ecs
#   ./scripts/terraform-apply.sh --env production --db-password "$DB_PASS"
#   ./scripts/terraform-apply.sh --env staging --plan-only    # plan but do not apply
#   ./scripts/terraform-apply.sh --env staging --destroy      # DANGEROUS: tear down
#
# Platforms:
#   eks  (default) → infra/terraform/      VPC + EKS + RDS + ElastiCache
#   ecs            → infra/terraform/ecs/  VPC + ECR + ECS Fargate + ALB + RDS + ElastiCache

source "$(dirname "$0")/lib.sh"

ENVIRONMENT=""
PLATFORM="eks"
DB_PASSWORD="${DB_PASSWORD:-}"
PLAN_ONLY=false
DESTROY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)          ENVIRONMENT="$2";   shift 2 ;;
    --platform)     PLATFORM="$2";      shift 2 ;;
    --db-password)  DB_PASSWORD="$2";   shift 2 ;;
    --plan-only)    PLAN_ONLY=true;     shift   ;;
    --destroy)      DESTROY=true;       shift   ;;
    --help|-h)
      grep '^#' "$0" | head -14 | sed 's/^# \?//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

case "$PLATFORM" in
  eks) TF_DIR="$REPO_ROOT/infra/terraform"     ;;
  ecs) TF_DIR="$REPO_ROOT/infra/terraform/ecs" ;;
  *)   die "--platform must be 'eks' or 'ecs'" ;;
esac

[[ -z "$ENVIRONMENT" ]] && die "--env is required (development | staging | production)"

require terraform aws

# ── Safety gate for production destroy ────────────────────────────────────────
if [[ "$DESTROY" == "true" && "$ENVIRONMENT" == "production" ]]; then
  error "Refusing to destroy the production environment automatically."
  error "If you genuinely need this, run terraform destroy manually from infra/terraform/."
  exit 1
fi

# ── Resolve DB password ────────────────────────────────────────────────────────
if [[ -z "$DB_PASSWORD" ]]; then
  if command -v aws &>/dev/null && [[ "$ENVIRONMENT" != "development" ]]; then
    info "DB_PASSWORD not set — attempting to fetch from AWS Secrets Manager..."
    DB_PASSWORD=$(aws secretsmanager get-secret-value \
      --secret-id "poly-orchestrator/${ENVIRONMENT}/db-password" \
      --query SecretString --output text 2>/dev/null || true)
  fi
  [[ -z "$DB_PASSWORD" ]] && \
    read -r -s -p "$(echo -e "${YELLOW}Enter DB password: ${RESET}")" DB_PASSWORD && echo ""
fi
[[ -z "$DB_PASSWORD" ]] && die "DB password is required"

# ── AWS identity ───────────────────────────────────────────────────────────────
step "AWS identity"
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null)
info "Account:  $(echo "$CALLER" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["Account"])')"
info "ARN:      $(echo "$CALLER" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["Arn"])')"
info "Env:      $ENVIRONMENT"
info "Platform: $PLATFORM  ($TF_DIR)"

# ── Init ───────────────────────────────────────────────────────────────────────
step "terraform init"
cd "$TF_DIR"
terraform init -input=false

# ── Plan ───────────────────────────────────────────────────────────────────────
PLAN_FILE="/tmp/poly-orchestrator-tfplan-${ENVIRONMENT}"

step "terraform plan (environment=$ENVIRONMENT)"
TF_VAR_ARGS=(
  -var "environment=$ENVIRONMENT"
  -var "db_password=$DB_PASSWORD"
)

if [[ "$DESTROY" == "true" ]]; then
  warn "DESTROY MODE — this will tear down all infrastructure in '$ENVIRONMENT'"
  terraform plan "${TF_VAR_ARGS[@]}" -destroy -out="$PLAN_FILE"
else
  terraform plan "${TF_VAR_ARGS[@]}" -out="$PLAN_FILE"
fi

[[ "$PLAN_ONLY" == "true" ]] && { info "Plan-only mode — exiting without apply."; exit 0; }

# ── Confirm ────────────────────────────────────────────────────────────────────
echo ""
if [[ "$DESTROY" == "true" ]]; then
  error "You are about to DESTROY the '$ENVIRONMENT' environment."
  confirm "Type 'y' to confirm destruction of '$ENVIRONMENT'"
else
  confirm "Apply the plan above to '$ENVIRONMENT'?"
fi

# ── Apply ──────────────────────────────────────────────────────────────────────
step "terraform apply"
terraform apply -input=false "$PLAN_FILE"

# ── Outputs ───────────────────────────────────────────────────────────────────
if [[ "$DESTROY" == "false" ]]; then
  step "Terraform outputs"
  terraform output
fi

rm -f "$PLAN_FILE"

echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Terraform apply complete!${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
if [[ "$DESTROY" == "false" ]]; then
  if [[ "$PLATFORM" == "eks" ]]; then
    echo "  Next steps (EKS):"
    echo "    aws eks update-kubeconfig --region us-east-1 --name poly-orchestrator-${ENVIRONMENT}"
    echo "    ./scripts/k8s-deploy.sh --image <ecr-url>:latest"
  else
    echo "  Next steps (ECS):"
    ECR_URL=$(terraform output -raw ecr_repository_url 2>/dev/null || echo "<ecr-url>")
    echo "    # Push image to ECR"
    echo "    aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_URL"
    echo "    docker tag poly-orchestrator:local $ECR_URL:latest"
    echo "    docker push $ECR_URL:latest"
    echo ""
    echo "    # Run migrations (one-shot Fargate task)"
    echo "    aws ecs run-task --cluster poly-orchestrator-${ENVIRONMENT} \\"
    echo "      --task-definition poly-orchestrator-${ENVIRONMENT} --launch-type FARGATE \\"
    echo "      --network-configuration 'awsvpcConfiguration={subnets=[...],securityGroups=[...]}' \\"
    echo "      --overrides '{\"containerOverrides\":[{\"name\":\"app\",\"command\":[\"python\",\"-m\",\"alembic\",\"upgrade\",\"head\"]}]}'"
    echo ""
    echo "    # Trigger rolling deploy"
    echo "    aws ecs update-service --cluster poly-orchestrator-${ENVIRONMENT} \\"
    echo "      --service poly-orchestrator-${ENVIRONMENT} --force-new-deployment"
    ALB_URL=$(terraform output -raw alb_dns_name 2>/dev/null || echo "<alb-dns>")
    echo ""
    echo "  API: http://$ALB_URL"
  fi
fi
