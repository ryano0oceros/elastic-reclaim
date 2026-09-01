output "elastic_project_id" {
  value = module.elastic.project_id
}

output "elastic_kibana_endpoint" {
  value = module.elastic.kibana_endpoint
}

output "eis_endpoint_url" {
  description = "Value injected into the proxy container as EIS_ENDPOINT_URL."
  value       = module.elastic.elasticsearch_endpoint
}

output "eis_model_map" {
  description = "Model alias -> inference_id map, injected into the proxy container as EIS_MODEL_MAP. Aliases here should match opencode/opencode.json's provider.eis-proxy.models keys."
  value       = module.elastic.inference_endpoints
}

output "ecr_repository_url" {
  description = "docker push target - build/push the proxy image here, then the ECS service will pick it up."
  value       = module.aws.ecr_repository_url
}

output "ecs_cluster_name" {
  value = module.aws.ecs_cluster_name
}

output "ecs_service_name" {
  value = module.aws.ecs_service_name
}

output "proxy_base_url" {
  description = "Stable base URL for OpenAI-compatible clients - set OPENAI_API_BASE to this. Survives deployments."
  value       = "http://${module.aws.alb_dns_name}/v1"
}

output "proxy_api_key" {
  description = "Bearer token OpenCode must send to the proxy. Read with `terraform output -raw proxy_api_key` and set it as OPENAI_API_KEY in opencode/.env."
  value       = random_password.proxy_api_key.result
  sensitive   = true
}

output "proxy_public_ip_command" {
  description = "Run this after the service is stable to find the proxy's current public IP."
  value       = module.aws.task_public_ip_command
}

output "default_model_alias" {
  description = "Alias scripts/dev-setup.sh sets as a new developer's default model."
  value       = var.default_model_alias
}
