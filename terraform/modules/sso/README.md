# SSO module (placeholder - later phase)

**Status: not implemented. Nothing in this folder is wired into the root
module.** It exists so the SSO design decision is recorded where the
implementation will live.

## Why this is deferred

The PoC authenticates every developer with one shared bearer token, and
attributes usage via a self-reported `X-EIS-User` header that each
developer's generated config sends (see `scripts/dev-setup.sh`). That is
honor-system attribution: fine for a trusted internal pilot, unacceptable
for anything with per-user billing, quotas, or audit requirements.

## Planned design

The ALB added in the analytics phase is the natural insertion point:

1. **ALB `authenticate-oidc` listener action** in front of the forward
   action, pointed at the customer's IdP (Okta, Entra ID, or AWS Cognito as
   a broker). Unauthenticated requests get redirected to the IdP; the ALB
   validates the session and forwards identity headers.
2. **Proxy reads `x-amzn-oidc-data`** (a JWT signed by the ALB) instead of
   the self-reported `X-EIS-User` header. The proxy must verify the JWT
   signature against the ALB's regional public key - do not trust the
   header alone if port 8000 is ever reachable without the ALB.
3. **Retire the shared `PROXY_API_KEY`** once OIDC is enforced, or keep it
   as a break-glass credential stored in Secrets Manager.
4. **Usage events** then carry a verified identity, making the per-user
   dashboards trustworthy for chargeback/showback.

Caveats discovered while scoping:

- ALB OIDC requires an **HTTPS listener**, so the TLS work (domain + ACM
  certificate, see README "Future enhancements") is a hard prerequisite -
  sequence TLS first.
- OpenCode must be able to complete a browser-based OIDC flow or use a
  device-code flow; if the IdP can't support that for CLI clients, an
  alternative is per-user long-lived tokens minted by this module
  (Terraform `for_each` over a developer list) as an intermediate step.

## Files

- `variables.tf` - the interface the module will expose (commented out).
- `main.tf` - resource sketch (commented out).
