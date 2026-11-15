terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

resource "oci_core_vcn" "this" {
  for_each = local.vcn

  compartment_id = each.value.compartment_id
  cidr_blocks    = each.value.cidrs
  display_name   = each.value.display_name
  dns_label      = each.value.dns_label
  freeform_tags  = var.freeform_tags
}

# lock_default_security_list: true 인 VCN 은 Default Security List 의 규칙을 모두 비움
resource "oci_core_default_security_list" "lockdown" {
  for_each = { for vk, v in local.vcn : vk => v if v.lock_default_security_list }

  manage_default_resource_id = oci_core_vcn.this[each.key].default_security_list_id
  compartment_id             = each.value.compartment_id
  display_name               = "Default Security List for ${each.value.display_name}"
  freeform_tags              = var.freeform_tags
}

resource "oci_core_internet_gateway" "this" {
  for_each = local.igw

  compartment_id = each.value.compartment_id
  vcn_id         = oci_core_vcn.this[each.value.vcn_key].id
  display_name   = each.value.display_name
  enabled        = each.value.enabled
  freeform_tags  = var.freeform_tags
}

# ── Oracle Services Network ──────────────────────────────────
data "oci_core_services" "all" {}

locals {
  svc_all = one([for s in data.oci_core_services.all.services : s if can(regex("^All .* Services In Oracle Services Network$", s.name))])
  svc_os  = one([for s in data.oci_core_services.all.services : s if can(regex("Object Storage$", s.name))])

  # YAML 키워드 → service id / service CIDR label
  service_id = {
    "all-services"  = try(local.svc_all.id, null)
    "objectstorage" = try(local.svc_os.id, null)
  }
  service_cidr = {
    "all-services"  = try(local.svc_all.cidr_block, null)
    "objectstorage" = try(local.svc_os.cidr_block, null)
  }
}

resource "oci_core_service_gateway" "this" {
  for_each = local.sgw

  compartment_id = each.value.compartment_id
  vcn_id         = oci_core_vcn.this[each.value.vcn_key].id
  display_name   = each.value.display_name
  route_table_id = each.value.route_table == null ? null : lookup(local.rt_sgw_ids, each.value.route_table, null)
  freeform_tags  = var.freeform_tags

  services {
    service_id = lookup(local.service_id, each.value.services, null)
  }
}
