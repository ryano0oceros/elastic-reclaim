#!/usr/bin/env bash
# One-command build-and-deploy for the platform team.
#
# Builds the proxy image for linux/amd64 (Fargate is X86_64 - a native Apple
# Silicon build dies with an exec-format error), pushes it under a unique tag
# (ECR is immutable), rolls the ECS service, waits for stability, and smoke
# tests through the ALB.
#
# Prereqs: aws CLI authenticated, docker running, terraform/terraform.tfvars
# populated, and a first `terraform apply` already done (this script deploys
# code; it does not bootstrap credentials).

set -euo pipefail
cd "$(dirname "$0")/.."

TF="terraform -chdir=terraform"
REPO_URL=$($TF output -raw ecr_repository_url)
REGION=$(echo "$REPO_URL" | sed -E 's/^[0-9]+\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com.*/\1/')
TAG=$(git rev-parse --short HEAD)$(git diff --quiet || echo "-dirty-$(date +%s)")
CLUSTER=$($TF output -raw ecs_cluster_name)
SERVICE=$($TF output -raw ecs_service_name)

echo "==> Building $REPO_URL:$TAG (linux/amd64)"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${REPO_URL%%/*}" >/dev/null
docker build --platform linux/amd64 -t "$REPO_URL:$TAG" proxy
docker push "$REPO_URL:$TAG"

# Confirm the tag is really in the registry before pointing ECS at it.
# A push that fails (or is silently skipped) otherwise surfaces much later
# as CannotPullContainerError, while the previous task keeps serving and
# everything looks healthy.
echo "==> Verifying $TAG exists in ECR"
aws ecr describe-images --region "$REGION" \
  --repository-name "${REPO_URL##*/}" --image-ids imageTag="$TAG" >/dev/null

echo "==> Applying image_tag=$TAG"
# Persist the tag so a later plain `terraform apply` (dashboards, model list,
# etc.) keeps deploying this image instead of regressing to the variable
# default - which points at a tag that was never pushed.
echo "image_tag = \"$TAG\"" > terraform/image_tag.auto.tfvars
$TF apply -input=false -auto-approve

echo "==> Rolling ECS service"
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
  --force-new-deployment >/dev/null
aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE"

BASE_URL=$($TF output -raw proxy_base_url)
echo "==> Smoke test: ${BASE_URL%/v1}/health"
curl -fsS --max-time 20 "${BASE_URL%/v1}/health"
echo
echo "==> Deployed. Developers point OPENAI_API_BASE at: $BASE_URL"
echo "    Onboard a developer with: scripts/dev-setup.sh <username>"
