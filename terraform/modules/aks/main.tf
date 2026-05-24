resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name

  # Workload Identity + OIDC issuer — required for n8n → AOAI tokenless auth
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  # Azure Policy add-on (Gatekeeper). Originally disabled in Phase 1C
  # (ADR-0001) but CSPM re-enables it anyway, and Phase 3.7 Image Integrity
  # uses it as the enforcement engine. Source of truth flipped in ADR-0018.
  azure_policy_enabled = true

  default_node_pool {
    name                         = "system"
    node_count                   = var.system_node_count
    vm_size                      = var.system_node_vm_size
    type                         = "VirtualMachineScaleSets"
    only_critical_addons_enabled = false # lab: workload pods run here for now
    os_disk_size_gb              = 30
    # Required by AzureRM ~> 4.0 for in-place vm_size changes on the default
    # pool: AKS spins up a parallel pool with this name using the new SKU,
    # cordon+drains the old pool, then promotes the new one. Without this
    # field a vm_size change would force cluster recreation. See ADR-0018.
    temporary_name_for_rotation = "systmp"
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"
  }

  # Container Insights → Log Analytics from day 1 (Defender layered on in Phase 3)
  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_id
    msi_auth_for_monitoring_enabled = true
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, # autoscaler-friendly
      # microsoft_defender is enabled/disabled out-of-band via
      # `az aks update --enable-defender` (Phase 3.3) so the workspace
      # association is managed there, not in TF. See ADR-0018.
      microsoft_defender,
    ]
  }
}

# Allow AKS kubelet identity to pull from ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = var.acr_id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# AKS diagnostic settings → Log Analytics
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_id

  enabled_log {
    category = "kube-apiserver"
  }
  enabled_log {
    category = "kube-audit-admin"
  }
  enabled_log {
    category = "kube-controller-manager"
  }
  enabled_log {
    category = "kube-scheduler"
  }
  enabled_log {
    category = "cluster-autoscaler"
  }

  metric {
    category = "AllMetrics"
  }
}
