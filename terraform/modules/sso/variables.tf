# Placeholder - see README.md. Interface sketch for the later-phase SSO
# module; intentionally commented out so `terraform validate` treats this
# folder as inert until the work is scheduled.
#
# variable "oidc_issuer" {
#   description = "IdP issuer URL (e.g. https://login.example.okta.com)."
#   type        = string
# }
#
# variable "oidc_client_id" {
#   description = "OAuth client id registered for the EIS proxy."
#   type        = string
# }
#
# variable "oidc_client_secret" {
#   description = "OAuth client secret."
#   type        = string
#   sensitive   = true
# }
#
# variable "https_listener_arn" {
#   description = "The ALB HTTPS listener to attach authenticate-oidc to (TLS is a prerequisite)."
#   type        = string
# }
