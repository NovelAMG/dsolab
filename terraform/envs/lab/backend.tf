terraform {
  required_version = ">= 1.6.0"

  backend "azurerm" {
    # Values supplied at init time via -backend-config flags
    # (see scripts/00-bootstrap-state.sh output for the one-liner).
    #
    # Required keys:
    #   resource_group_name   = "rg-dsolab-sea"
    #   storage_account_name  = "stdsolabtfstate<random>"
    #   container_name        = "tfstate"
    #   key                   = "lab.tfstate"

    use_azuread_auth = true # No shared-key fallback; pure Entra auth.
  }
}
