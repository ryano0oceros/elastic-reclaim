terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    ec = {
      source  = "elastic/ec"
      version = "~> 0.13"
    }
    elasticstack = {
      source  = "elastic/elasticstack"
      version = "~> 0.16"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "ec" {
  apikey = var.ec_api_key
}

# No default connection here - every elasticstack_* resource (in
# modules/elastic) pins its own elasticsearch_connection block to the
# specific project it belongs to, since that connection info only exists
# once the ec_elasticsearch_project resource has been created.
provider "elasticstack" {
  elasticsearch {}
}
