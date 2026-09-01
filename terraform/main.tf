# Elastic Serverless project hosting the EIS-backed chat_completion inference
# endpoint. Swap this module for a different Elastic provisioning strategy
# (e.g. a hosted deployment) without touching the AWS module or root wiring.
module "elastic" {
  source = "./modules/elastic"

  project_name    = "${var.project_name}-elastic"
  region_id       = var.ec_region
  organization_id = var.ec_organization_id
  eis_models      = var.eis_models
}

# NOTE: modules/sso is a deliberate placeholder for a later phase - ALB
# authenticate-oidc replacing the shared bearer token and the self-reported
# X-EIS-User header. See modules/sso/README.md; TLS is its prerequisite.

# AWS compute hosting the FastAPI proxy that translates OpenAI chat
# completions into calls against the Elastic project above. To add another
# cloud provider (Azure/GCP), add modules/azure or modules/gcp with the same
# `environment` input contract and instantiate it here - no changes needed
# to modules/elastic or modules/aws.
module "aws" {
  source = "./modules/aws"

  project_name        = var.project_name
  vpc_cidr            = var.vpc_cidr
  container_port      = var.container_port
  image_tag           = var.image_tag
  desired_count       = var.desired_count
  allowed_cidr_blocks = var.allowed_cidr_blocks

  environment = {
    EIS_ENDPOINT_URL    = module.elastic.elasticsearch_endpoint
    CAPTURE_LLM_TRAFFIC = var.capture_requests ? "true" : "false"
    # JSON map of model alias -> inference_id, e.g. {"claude":"...","gemini":"...","gpt":"..."}.
    # The proxy looks up the incoming OpenAI-style `model` field in this map
    # per request - see proxy/app/config.py and proxy/app/main.py.
    EIS_MODEL_MAP = jsonencode(module.elastic.inference_endpoints)
    # Per-model token rates for spend attribution; see var.model_pricing.
    # Strip unset optional() fields: Terraform serializes them as JSON null,
    # which fails the proxy's numeric validation and would crash-loop the task.
    EIS_MODEL_PRICING = jsonencode({
      for alias, rates in var.model_pricing : alias => {
        for field, value in rates : field => value if value != null
      }
    })
  }

  secrets = {
    # Scoped Elasticsearch API key minted by modules/elastic - NOT the
    # organization-level ec_api_key, which only authenticates to the Cloud
    # control-plane API and can't call this project's Elasticsearch REST API.
    ELASTIC_API_KEY = module.elastic.proxy_api_key
    # Bearer token OpenCode must present. Without this the proxy would be an
    # open relay: it holds a live Elastic key and bills real inference, so
    # anyone who found the public IP could spend the org's budget.
    PROXY_API_KEY = random_password.proxy_api_key.result
  }
}

# Generated rather than user-supplied so a weak or reused token can't be
# introduced by hand. Read it with:
#   terraform output -raw proxy_api_key
resource "random_password" "proxy_api_key" {
  length  = 48
  special = false
}
