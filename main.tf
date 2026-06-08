terraform {
  required_version = ">= 1.5.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 2.0"
    }
  }
}

provider "openstack" {
  auth_url    = "http://10.147.165.100/identity/v3"
  region      = "RegionOne"
  user_name   = "admin"
  password    = "admin123"
  tenant_name = "admin"
  domain_name = "Default"
  insecure    = true
}

variable "tenant_mano_config" {
  type = map(object({
    segment_id = number
    vrf_name   = string
    cidr_block = string
  }))
  default = {
    "tenant-enterprise-alpha" = { segment_id = 10100, vrf_name = "VRF_ALPHA", cidr_block = "10.100.10.0/24" }
    "tenant-enterprise-beta"  = { segment_id = 10200, vrf_name = "VRF_BETA",  cidr_block = "10.200.10.0/24" }
  }
}

resource "openstack_networking_network_v2" "tenant_vxlan_fabric" {
  for_each       = var.tenant_mano_config
  name           = "${each.key}-net"
  admin_state_up = true
  segments {
    network_type    = "geneve"
    segmentation_id = each.value.segment_id
  }
}

resource "openstack_networking_subnet_v2" "tenant_subnets" {
  for_each    = var.tenant_mano_config
  name        = "${each.key}-subnet"
  network_id  = openstack_networking_network_v2.tenant_vxlan_fabric[each.key].id
  cidr        = each.value.cidr_block
  ip_version  = 4
  enable_dhcp = false
}

output "allocated_vim_segments" {
  value       = { for k, v in openstack_networking_network_v2.tenant_vxlan_fabric : k => v.id }
  description = "Allocated multi-tenant logical segments mapped to the core NFVI infrastructure layer."
}
