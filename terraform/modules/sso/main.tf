# Placeholder - see README.md. Resource sketch for the later-phase SSO
# module. The authenticate-oidc action attaches to the HTTPS listener that
# the TLS enhancement will add; it cannot attach to the current HTTP:80
# listener, which is why TLS must land first.
#
# resource "aws_lb_listener_rule" "oidc" {
#   listener_arn = var.https_listener_arn
#   priority     = 10
#
#   action {
#     type = "authenticate-oidc"
#     authenticate_oidc {
#       issuer                 = var.oidc_issuer
#       authorization_endpoint = "${var.oidc_issuer}/oauth2/v1/authorize"
#       token_endpoint         = "${var.oidc_issuer}/oauth2/v1/token"
#       user_info_endpoint     = "${var.oidc_issuer}/oauth2/v1/userinfo"
#       client_id              = var.oidc_client_id
#       client_secret          = var.oidc_client_secret
#     }
#   }
#
#   action {
#     type             = "forward"
#     target_group_arn = var.target_group_arn
#   }
#
#   condition {
#     path_pattern { values = ["/*"] }
#   }
# }
