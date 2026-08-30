terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.3"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  # Skip auto-registration of Azure Resource Providers. The GitHub Actions MI
  # has Contributor scoped to the resource group, not the subscription — so it
  # cannot register RPs at /subscriptions/ scope. Pre-register the needed RPs
  # manually via scripts/01-register-resource-providers.sh (one-time, as Owner).
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false # lab: easy teardown
    }
    key_vault {
      purge_soft_delete_on_destroy = true # lab: don't keep tombstones
    }
  }
}

provider "azuread" {}

provider "azapi" {}
