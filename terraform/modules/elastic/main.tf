# NOTE: ec_elasticsearch_project is in technical preview upstream (elastic/ec provider).
# Its schema may change between provider releases - pin the provider version (see versions.tf)
# and re-check `terraform providers schema` before upgrading.
#
# The `ec` provider itself is configured once in the root module (see ../../versions.tf)
# and inherited implicitly by this child module - no provider block is declared here.

resource "ec_elasticsearch_project" "this" {
  name          = var.project_name
  region_id     = var.region_id
  optimized_for = var.optimized_for

  metadata = {
    tags = {
      organization_id = var.organization_id
      managed_by      = "terraform"
      purpose         = "eis-proxy-poc"
    }
  }
}

# ec_elasticsearch_project.credentials is only populated in the create
# response (see the resource's upstream docs) - it is not reissued on
# refresh/import. Every elasticstack_* resource below pins its own
# elasticsearch_connection to these values instead of relying on the
# elasticstack provider's default connection, precisely so that connection
# can depend on a same-apply resource without a provider-config chicken/egg
# problem. If this project is ever imported instead of created fresh, these
# credentials won't be available and these resources will need a different
# auth path (e.g. a manually-issued API key fed in as a variable).
locals {
  elasticsearch_connection = {
    endpoints = [ec_elasticsearch_project.this.endpoints.elasticsearch]
    username  = ec_elasticsearch_project.this.credentials.username
    password  = ec_elasticsearch_project.this.credentials.password
  }
}

# One EIS chat_completion endpoint per selectable model (see var.eis_models),
# rather than relying on the preconfigured default (`.rainbow-sprinkles-elastic`)
# - this way every model the proxy exposes is explicit and versioned in code.
# The map key (e.g. "claude") becomes both this resource's for_each key and
# the model name OpenCode's picker shows - see outputs.inference_endpoints.
resource "elasticstack_elasticsearch_inference_endpoint" "eis_chat_completion" {
  for_each = var.eis_models

  inference_id = "${var.project_name}-chat-${each.key}"
  task_type    = "chat_completion"
  service      = "elastic"

  service_settings = jsonencode({
    model_id = each.value
  })

  elasticsearch_connection {
    endpoints = local.elasticsearch_connection.endpoints
    username  = local.elasticsearch_connection.username
    password  = local.elasticsearch_connection.password
  }
}

# Scoped-down Elasticsearch API key for the proxy. This is what actually
# ends up in the ECS container's ELASTIC_API_KEY env var - NOT the
# organization-level ec_api_key used to authenticate the `ec` provider,
# which is a Cloud-control-plane credential and cannot call this project's
# Elasticsearch REST API at all.
resource "elasticstack_elasticsearch_security_api_key" "proxy" {
  name = "${var.project_name}-proxy"

  role_descriptors = jsonencode({
    eis-proxy-inference = {
      cluster = ["monitor_inference"]
      # Analytics writes only: create_doc cannot update or delete existing
      # documents, create_index lets the first write lazily create the data
      # stream, auto_configure permits the template-driven mapping. The key
      # still cannot read any data or touch any other index.
      indices = [
        {
          names      = ["eis-proxy-usage*", "eis-proxy-captures*"]
          privileges = ["create_doc", "create_index", "auto_configure"]
        }
      ]
    }
  })

  elasticsearch_connection {
    endpoints = local.elasticsearch_connection.endpoints
    username  = local.elasticsearch_connection.username
    password  = local.elasticsearch_connection.password
  }
}
