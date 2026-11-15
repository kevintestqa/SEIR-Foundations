#!/usr/bin/env bash
# SEIR Foundations — Module 3 / Lab 01
# Automates install.md: preflight checks, local test, ECS deploy, verification, cleanup.
#
# Usage: ./install.sh [all|check|test|deploy|verify|cleanup] [--yes]
#   all      check + test + deploy + verify (default)
#   check    Step 1: tools, AWS identity, default VPC, lab files
#   test     Step 2: build and run the image locally, validate output
#   deploy   Step 3: run deploy.sh (Option A)
#   verify   Step 4: CLI equivalent of the console checks
#   cleanup  Step 7: delete cluster, ECR repo, log group (asks first unless --yes)
#
# Run from the extracted seir_cobol_ecs_lab directory (next to deploy.sh).
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
export AWS_REGION

REPO=seir-cobol-finance
TAG=lab1
CLUSTER=seir-module3
FAMILY=seir-cobol-batch
LOGGROUP=/ecs/seir-cobol-batch
SG_NAME=seir-cobol-no-ingress

EXPECTED_LINES=(
  "SEIR COBOL FINANCIAL BATCH v1"
  "Opening: USD 0012500.00"
  "Debit:   USD 0000250.00"
  "Closing: USD 0012250.00"
  "FINANCIAL INVARIANT PASSED"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ASSUME_YES=false
CMD=all
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=true ;;
    all|check|test|deploy|verify|cleanup) CMD="$arg" ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*" >&2; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- Step 1
do_check() {
  step "Step 1: Check tools and AWS environment (region: $AWS_REGION)"

  for f in hello.cbl Dockerfile deploy.sh; do
    [[ -f "$f" ]] || die "$f not found in $SCRIPT_DIR — extract seir_cobol_ecs_lab.zip and run from there"
  done
  ok "Lab files present"

  command -v aws >/dev/null || die "AWS CLI not installed"
  aws --version 2>&1 | grep -q '^aws-cli/2' || die "AWS CLI v2 required (found: $(aws --version 2>&1))"
  ok "$(aws --version 2>&1)"

  command -v docker >/dev/null || die "Docker not installed"
  docker info >/dev/null 2>&1 || die "Docker daemon not running (start Docker Desktop / dockerd)"
  ok "$(docker --version)"

  if [[ "$(uname -m)" == arm64 || "$(uname -m)" == aarch64 ]]; then
    if docker buildx ls 2>/dev/null | grep -q 'linux/amd64'; then
      ok "ARM host with linux/amd64 build support"
    else
      warn "ARM host and linux/amd64 not listed by 'docker buildx ls' — the build may fail"
    fi
  fi

  local identity
  identity=$(aws sts get-caller-identity --query Arn --output text) || die "AWS CLI not authenticated"
  ok "AWS identity: $identity"

  local vpc
  vpc=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")
  [[ -n "$vpc" && "$vpc" != None ]] || die "No default VPC in $AWS_REGION"
  ok "Default VPC: $vpc"
}

# ---------------------------------------------------------------- Step 2
do_test() {
  step "Step 2: Build and test locally"

  docker build --platform linux/amd64 -t "${REPO}:${TAG}" . || die "Docker build failed (COBOL compile error?) — do not deploy"
  ok "Image built: ${REPO}:${TAG}"

  local output rc=0
  output=$(docker run --rm --platform linux/amd64 "${REPO}:${TAG}" 2>&1) || rc=$?
  printf '%s\n' "$output" | sed 's/^/    | /'
  [[ $rc -eq 0 ]] || die "Container exited with code $rc — do not deploy"

  for line in "${EXPECTED_LINES[@]}"; do
    grep -qF -- "$line" <<<"$output" || die "Expected output missing: '$line'"
  done
  ok "Exit code 0 and all expected lines present"
}

# ---------------------------------------------------------------- Step 3
do_deploy() {
  step "Step 3: Deploy to ECS Fargate via deploy.sh"

  if [[ -f terraform/terraform.tfstate ]] && grep -q '"resources": \[[^]]' terraform/terraform.tfstate 2>/dev/null; then
    warn "terraform/terraform.tfstate has resources — Options A and B collide; pick one"
  fi

  chmod +x deploy.sh
  ./deploy.sh || die "deploy.sh failed — check the task's stopped reason and logs above"
  ok "ECS task completed with exit code 0"
}

# ---------------------------------------------------------------- Step 4
do_verify() {
  step "Step 4: Verify resources"
  local failed=0

  # ECR image
  if aws ecr describe-images --repository-name "$REPO" --image-ids imageTag="$TAG" \
       --region "$AWS_REGION" >/dev/null 2>&1; then
    ok "ECR: ${REPO}:${TAG} exists"
  else
    warn "ECR: ${REPO}:${TAG} not found"; failed=1
  fi

  # Most recent stopped task (ECS keeps stopped tasks visible for a limited time)
  local task
  task=$(aws ecs list-tasks --cluster "$CLUSTER" --family "$FAMILY" --desired-status STOPPED \
         --query 'taskArns[0]' --output text --region "$AWS_REGION" 2>/dev/null | head -n 1)
  if [[ -n "$task" && "$task" != None ]]; then
    local exit_code reason
    exit_code=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" \
                --query 'tasks[0].containers[0].exitCode' --output text --region "$AWS_REGION")
    reason=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" \
             --query 'tasks[0].stoppedReason' --output text --region "$AWS_REGION")
    if [[ "$exit_code" == 0 ]]; then
      ok "ECS: stopped task exit code 0 ($reason)"
    else
      warn "ECS: task exit code $exit_code ($reason)"; failed=1
    fi
  else
    warn "ECS: no stopped tasks visible in $CLUSTER (they expire after a while)"
  fi

  # CloudWatch log line from the last hour
  local since hits
  since=$(( ($(date +%s) - 3600) * 1000 ))
  # The CLI auto-paginates and applies --query per page, so count IDs rather than using length()
  hits=$(aws logs filter-log-events --log-group-name "$LOGGROUP" --start-time "$since" \
         --filter-pattern '"FINANCIAL INVARIANT PASSED"' \
         --query 'events[].eventId' --output text --region "$AWS_REGION" 2>/dev/null | wc -w | tr -d ' ')
  if [[ "$hits" -gt 0 ]]; then
    ok "CloudWatch: 'FINANCIAL INVARIANT PASSED' found in $LOGGROUP"
  else
    warn "CloudWatch: invariant line not found in $LOGGROUP in the last hour"; failed=1
  fi

  # Security group has no inbound rules
  local vpc ingress
  vpc=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")
  ingress=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=${vpc}" "Name=group-name,Values=${SG_NAME}" \
            --query 'length(SecurityGroups[0].IpPermissions)' --output text --region "$AWS_REGION" 2>/dev/null || echo missing)
  if [[ "$ingress" == 0 ]]; then
    ok "Security group $SG_NAME: no inbound rules"
  else
    warn "Security group $SG_NAME: inbound rules = $ingress"; failed=1
  fi

  [[ $failed -eq 0 ]] || die "Verification found problems (see warnings above)"
  ok "All checks passed"
}

# ---------------------------------------------------------------- Step 7
do_cleanup() {
  step "Step 7: Cleanup (region: $AWS_REGION)"
  echo "  Deletes: ECS cluster $CLUSTER, ECR repo $REPO (with images), log group $LOGGROUP"
  echo "  Keeps:   IAM role, security group $SG_NAME, default VPC"
  echo "  Only run this if these resources belong exclusively to YOUR lab."

  if [[ "$ASSUME_YES" != true ]]; then
    read -r -p "  Type 'delete' to continue: " answer
    [[ "$answer" == delete ]] || { echo "  Aborted."; exit 0; }
  fi

  local status
  status=$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' \
           --output text --region "$AWS_REGION" 2>/dev/null || echo None)
  if [[ "$status" == ACTIVE ]]; then
    local running services
    running=$(aws ecs list-tasks --cluster "$CLUSTER" --query 'taskArns[]' --output text --region "$AWS_REGION" | wc -w | tr -d ' ')
    services=$(aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text --region "$AWS_REGION" | wc -w | tr -d ' ')
    if [[ "$running" != 0 || "$services" != 0 ]]; then
      warn "Cluster $CLUSTER has $running running task(s) and $services service(s) — not deleting it"
    else
      aws ecs delete-cluster --cluster "$CLUSTER" --region "$AWS_REGION" >/dev/null
      ok "Deleted ECS cluster $CLUSTER"
    fi
  else
    ok "ECS cluster $CLUSTER not present"
  fi

  if aws ecr describe-repositories --repository-names "$REPO" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws ecr delete-repository --repository-name "$REPO" --force --region "$AWS_REGION" >/dev/null
    ok "Deleted ECR repository $REPO"
  else
    ok "ECR repository $REPO not present"
  fi

  if aws logs delete-log-group --log-group-name "$LOGGROUP" --region "$AWS_REGION" 2>/dev/null; then
    ok "Deleted log group $LOGGROUP"
  else
    ok "Log group $LOGGROUP not present"
  fi

  echo "  If you used Terraform (Option B), run 'terraform destroy' in terraform/ instead."
}

case "$CMD" in
  check)   do_check ;;
  test)    do_test ;;
  deploy)  do_deploy ;;
  verify)  do_verify ;;
  cleanup) do_cleanup ;;
  all)     do_check; do_test; do_deploy; do_verify
           step "Done. Run './install.sh cleanup' when you are finished with the lab." ;;
esac
