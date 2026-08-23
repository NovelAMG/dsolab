variable "prefix" {
  description = "Naming prefix for all resources"
  type        = string
  default     = "dsolab"
}

variable "location_primary" {
  description = "Primary Azure region (AKS, ACR, KV, Postgres)"
  type        = string
  default     = "southeastasia"
}

variable "location_aoai" {
  description = "Azure OpenAI region (split out for GPT-4o availability)"
  type        = string
  default     = "australiaeast"
}

variable "resource_group_name" {
  description = "Resource group for all lab resources (created by bootstrap script)"
  type        = string
  default     = "rg-dsolab-sea"
}

variable "github_repo" {
  description = "GitHub org/repo for OIDC federated credential subjects"
  type        = string
  default     = "NovelAMG/dsolab"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    project     = "dsolab"
    environment = "lab"
    managed_by  = "terraform"
    # Does NOT exempt AKS. The cost automation deletes this tag off the cluster
    # regardless of casing (both `costcontrol=ignore` and `CostControl=Ignore`
    # were stripped within hours, per Resource Graph resourcechanges), so the
    # AKS module ignore_changes tags and uptime is handled by the unflip
    # workflow instead. Kept here because it does persist on the other resources.
    CostControl = "Ignore"
  }
}

variable "human_admin_object_id" {
  description = <<-EOT
    Object ID of the human admin who should retain Key Vault Administrator access
    even when Terraform runs as the GitHub Actions MI. Set via TF_VAR or via the
    HUMAN_ADMIN_OID GitHub repo variable (populated by the bootstrap script).
    If null/empty, only the TF runner principal gets KV access.
  EOT
  type        = string
  default     = null
}

# ───── Phase 1D inputs (set by scripts/02-create-entra-apps.sh) ─────

variable "spa_app_id" {
  description = "SPA app reg client ID (Phase 1E uses this for MSAL config). Set via TF_VAR or GitHub repo variable SPA_APP_ID."
  type        = string
  default     = null
}

variable "n8n_api_app_id" {
  description = "n8n-api app reg client ID. Set via TF_VAR or GitHub repo variable N8N_API_APP_ID."
  type        = string
  default     = null
}

variable "n8n_api_app_uri" {
  description = "n8n-api Application ID URI (e.g. api://n8n-dsolab) — the audience oauth2-proxy validates. Set via TF_VAR or GitHub repo variable N8N_API_APP_URI."
  type        = string
  default     = null
}
