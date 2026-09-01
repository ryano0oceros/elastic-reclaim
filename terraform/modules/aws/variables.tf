variable "project_name" {
  description = "Prefix applied to all AWS resource names/tags."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC created to host the Fargate proxy."
  type        = string
  default     = "10.42.0.0/16"
}

variable "container_port" {
  description = "Port the FastAPI proxy listens on inside the container."
  type        = number
  default     = 8000
}

variable "image_tag" {
  description = "Tag of the proxy image to deploy. The ECR repo is IMMUTABLE, so every build must use a new unique tag (e.g. a git SHA) rather than overwriting one."
  type        = string
  default     = "v1"
}

variable "desired_count" {
  description = "Number of Fargate tasks to run for the proxy service."
  type        = number
  default     = 1
}

variable "task_cpu" {
  description = "Fargate task vCPU units (256 = .25 vCPU)."
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = string
  default     = "512"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the proxy on container_port. Restrict this beyond the PoC default of 0.0.0.0/0 before using real credentials."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the proxy container's log group."
  type        = number
  default     = 14
}

variable "environment" {
  description = "Non-sensitive environment variables for the proxy container, set directly in the task definition (e.g. EIS_ENDPOINT_URL, EIS_MODEL_MAP)."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Sensitive environment variables for the proxy container (e.g. ELASTIC_API_KEY, PROXY_API_KEY). Each becomes a Secrets Manager secret referenced by the task definition's `secrets` block, so the values are never stored in the task definition itself."
  type        = map(string)
  sensitive   = true
}
