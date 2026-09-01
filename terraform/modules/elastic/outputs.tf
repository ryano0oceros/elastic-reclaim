output "project_id" {
  description = "ID of the Elastic Serverless Elasticsearch project."
  value       = ec_elasticsearch_project.this.id
}

output "elasticsearch_endpoint" {
  description = "Base Elasticsearch endpoint URL for the project. The proxy appends /_inference/chat_completion/{id}/_stream to this."
  value       = ec_elasticsearch_project.this.endpoints.elasticsearch
}

output "kibana_endpoint" {
  description = "Kibana endpoint URL for the project (useful for manually inspecting/creating inference endpoints)."
  value       = ec_elasticsearch_project.this.endpoints.kibana
}

output "cloud_id" {
  description = "Encoded cloud ID for the project."
  value       = ec_elasticsearch_project.this.cloud_id
}

output "inference_endpoints" {
  description = "Map of model alias (from var.eis_models) -> the inference_id created for it. Feeds the proxy's EIS_MODEL_MAP for request-time model routing."
  value       = { for alias, ep in elasticstack_elasticsearch_inference_endpoint.eis_chat_completion : alias => ep.inference_id }
}

output "proxy_api_key" {
  description = "Elasticsearch API key (base64 id:key, ready for an `Authorization: ApiKey` header) scoped to only call inference - this is what the proxy's ELASTIC_API_KEY should be set to."
  value       = elasticstack_elasticsearch_security_api_key.proxy.encoded
  sensitive   = true
}
