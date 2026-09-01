# Secrets reach the container through ECS's `secrets` block (resolved by the
# ECS agent at task start) rather than `environment`. With `environment`, the
# values are baked into the task definition, which means anyone holding
# ecs:DescribeTaskDefinition - a common read-only grant - can read the live
# Elastic API key, and every historical revision keeps its copy forever.

resource "aws_secretsmanager_secret" "proxy" {
  # for_each keys become resource addresses, so they cannot be sensitive.
  # Only the *values* of var.secrets are secret - the keys are env var names
  # (ELASTIC_API_KEY, PROXY_API_KEY), so unwrapping just the key set is safe.
  for_each = nonsensitive(toset(keys(var.secrets)))

  name = "${var.project_name}/proxy/${lower(each.key)}"
  # PoC-friendly: allows a destroy/re-apply cycle without tripping the 7-day
  # minimum recovery window on a name that is about to be reused.
  recovery_window_in_days = 0

  tags = {
    Name = "${var.project_name}-proxy-${lower(each.key)}"
  }
}

resource "aws_secretsmanager_secret_version" "proxy" {
  # for_each keys become resource addresses, so they cannot be sensitive.
  # Only the *values* of var.secrets are secret - the keys are env var names
  # (ELASTIC_API_KEY, PROXY_API_KEY), so unwrapping just the key set is safe.
  for_each = nonsensitive(toset(keys(var.secrets)))

  secret_id     = aws_secretsmanager_secret.proxy[each.key].id
  secret_string = var.secrets[each.key]
}

# Grants the *execution* role (not the task) permission to read exactly these
# secrets - the ECS agent injects them before the container starts, so the
# application itself never needs AWS credentials.
data "aws_iam_policy_document" "read_proxy_secrets" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for secret in aws_secretsmanager_secret.proxy : secret.arn]
  }
}

resource "aws_iam_role_policy" "read_proxy_secrets" {
  name   = "${var.project_name}-read-proxy-secrets"
  role   = aws_iam_role.ecs_task_execution.id
  policy = data.aws_iam_policy_document.read_proxy_secrets.json
}
