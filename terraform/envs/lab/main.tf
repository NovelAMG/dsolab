# Phase 1A: bootstrap only. Modules added in Phase 1B (AKS, ACR, AOAI, KV, Postgres).
#
# This file is intentionally minimal so `terraform init` + `terraform plan` succeed
# with zero resource changes — proving the backend, providers, and OIDC work.

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "lab" {
  name = var.resource_group_name
}
