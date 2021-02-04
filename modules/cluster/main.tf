data "azurerm_client_config" "current" {}

locals {
  consul_config = var.consul.mode != "disabled" ? templatefile("${path.module}/templates/consul_${var.consul.mode}.json", {
    instance_count  = var.instance_count,
    namespace       = var.namespace,
    datacenter      = var.datacenter,
    join_wan        = join(",", [for s in var.join_wan : join("", ["\"", s, "\""])]),
    resource_group  = var.resource_group_name,
    subscription_id = data.azurerm_subscription.primary.subscription_id
    vm_scale_sets = {
      consul_servers = "${var.namespace}-Ndisabled-Cserver"
    }
    advertise_addr = var.associate_public_ips ? "$PUBLIC_IP" : "$PRIVATE_IP"
    tag_name       = "name"
    tag_value      = "${var.namespace}-Ndisabled-Cserver"
  }) : ""
  nomad_config = var.nomad.mode != "disabled" ? templatefile("${path.module}/templates/nomad_${var.nomad.mode}.hcl", {
    instance_count = var.instance_count
    datacenter     = var.datacenter
    region         = var.location
    advertise_addr = var.associate_public_ips ? "$PUBLIC_IP" : "$PRIVATE_IP"
  }) : ""
  startup = templatefile("${path.module}/templates/startup.sh", {
    consul_version = var.consul.version,
    consul_config  = local.consul_config,
    consul_mode    = var.consul.mode
    nomad_version  = var.nomad.version,
    nomad_config   = local.nomad_config,
    nomad_mode     = var.nomad.mode,
  })
  namespace = "${var.namespace}-N${var.nomad.mode}-C${var.consul.mode}"
}

# Enable Boot Diagnostics
resource "random_string" "rand" {
  length  = 24
  special = false
  upper   = false
}

resource "azurerm_storage_account" "storage_account" {
  name                     = random_string.rand.result
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_virtual_machine_scale_set" "scale_set" {
  upgrade_policy_mode = "Automatic"
  name                = local.namespace
  resource_group_name = var.resource_group_name
  location            = var.location
  network_profile {
    name                      = "${local.namespace}-NetworkProfile"
    primary                   = true
    network_security_group_id = var.security_group_id
    ip_configuration {
      name = "${local.namespace}-IPConfiguration"

      primary                                = true
      subnet_id                              = var.vpc.subnets[0].id
      load_balancer_backend_address_pool_ids = var.lb_backend_address_pool_ids

      dynamic "public_ip_address_configuration" {
        for_each = var.associate_public_ips ? [1] : []
        content {
          name              = "PublicIPConfiguration"
          idle_timeout      = 5
          domain_name_label = lower(local.namespace)
        }
      }
    }
  }

  identity {
    type = "SystemAssigned"
  }

  os_profile {
    computer_name_prefix = local.namespace
    admin_username       = var.admin.username
    admin_password       = var.admin.password
    custom_data          = local.startup
  }

  os_profile_linux_config {
    disable_password_authentication = var.admin.disable_password_authentication
  }
  sku {
    name     = var.instance_size
    tier     = "standard"
    capacity = var.instance_count
  }

  storage_profile_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  storage_profile_os_disk {
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }

  boot_diagnostics {
    enabled     = true
    storage_uri = azurerm_storage_account.storage_account.primary_blob_endpoint
  }
}

data "azurerm_subscription" "primary" {}

resource "azurerm_role_assignment" "role_assignment" {
  scope                = data.azurerm_subscription.primary.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_virtual_machine_scale_set.scale_set.identity[0].principal_id
}

resource "azurerm_monitor_autoscale_setting" "autoscale_setting" {
  name                = "${local.namespace}-AutoscaleSetting"
  enabled             = true
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_virtual_machine_scale_set.scale_set.id

  profile {
    name = "${local.namespace}-Profile"

    capacity {
      default = var.instance_count
      minimum = var.instance_count
      maximum = var.instance_count
    }
  }
}
