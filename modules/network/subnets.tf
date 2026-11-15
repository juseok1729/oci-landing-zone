# 규칙 형식은 NSG 와 같다 (locals.tf fw_rules). CIDR 대신 all-services / objectstorage 도 가능
resource "oci_core_security_list" "this" {
  for_each = local.sl

  compartment_id = each.value.compartment_id
  vcn_id         = oci_core_vcn.this[each.value.vcn_key].id
  display_name   = each.value.display_name
  freeform_tags  = var.freeform_tags

  dynamic "ingress_security_rules" {
    for_each = each.value.ingress
    iterator = r
    content {
      source      = lookup(local.service_cidr, r.value.cidr, r.value.cidr)
      source_type = contains(keys(local.service_cidr), r.value.cidr) ? "SERVICE_CIDR_BLOCK" : "CIDR_BLOCK"
      protocol    = r.value.protocol
      stateless   = r.value.stateless
      description = r.value.description

      dynamic "tcp_options" {
        for_each = r.value.kind == "tcp" && (r.value.port_min != null || r.value.sport_min != null) ? [1] : []
        content {
          min = r.value.port_min
          max = r.value.port_max
          dynamic "source_port_range" {
            for_each = r.value.sport_min != null ? [1] : []
            content {
              min = r.value.sport_min
              max = r.value.sport_max
            }
          }
        }
      }
      dynamic "udp_options" {
        for_each = r.value.kind == "udp" && (r.value.port_min != null || r.value.sport_min != null) ? [1] : []
        content {
          min = r.value.port_min
          max = r.value.port_max
          dynamic "source_port_range" {
            for_each = r.value.sport_min != null ? [1] : []
            content {
              min = r.value.sport_min
              max = r.value.sport_max
            }
          }
        }
      }
      dynamic "icmp_options" {
        for_each = r.value.kind == "icmp" && r.value.icmp_type != null ? [1] : []
        content {
          type = r.value.icmp_type
          code = r.value.icmp_code
        }
      }
    }
  }

  dynamic "egress_security_rules" {
    for_each = each.value.egress
    iterator = r
    content {
      destination      = lookup(local.service_cidr, r.value.cidr, r.value.cidr)
      destination_type = contains(keys(local.service_cidr), r.value.cidr) ? "SERVICE_CIDR_BLOCK" : "CIDR_BLOCK"
      protocol         = r.value.protocol
      stateless        = r.value.stateless
      description      = r.value.description

      dynamic "tcp_options" {
        for_each = r.value.kind == "tcp" && (r.value.port_min != null || r.value.sport_min != null) ? [1] : []
        content {
          min = r.value.port_min
          max = r.value.port_max
          dynamic "source_port_range" {
            for_each = r.value.sport_min != null ? [1] : []
            content {
              min = r.value.sport_min
              max = r.value.sport_max
            }
          }
        }
      }
      dynamic "udp_options" {
        for_each = r.value.kind == "udp" && (r.value.port_min != null || r.value.sport_min != null) ? [1] : []
        content {
          min = r.value.port_min
          max = r.value.port_max
          dynamic "source_port_range" {
            for_each = r.value.sport_min != null ? [1] : []
            content {
              min = r.value.sport_min
              max = r.value.sport_max
            }
          }
        }
      }
      dynamic "icmp_options" {
        for_each = r.value.kind == "icmp" && r.value.icmp_type != null ? [1] : []
        content {
          type = r.value.icmp_type
          code = r.value.icmp_code
        }
      }
    }
  }
}

locals {
  sl_ids = { for k, s in oci_core_security_list.this : k => s.id }
}

resource "oci_core_subnet" "this" {
  for_each = local.subnet

  compartment_id             = each.value.compartment_id
  vcn_id                     = oci_core_vcn.this[each.value.vcn_key].id
  cidr_block                 = each.value.cidr
  display_name               = each.value.display_name
  dns_label                  = each.value.dns_label
  prohibit_public_ip_on_vnic = !each.value.public
  freeform_tags              = var.freeform_tags

  # 비어 있으면 VCN Default Security List, "default" 는 목록 안에서도 사용 가능
  security_list_ids = (
    length(each.value.security_lists) == 0
    ? [oci_core_vcn.this[each.value.vcn_key].default_security_list_id]
    : [
      for n in each.value.security_lists :
      n == "default" ? oci_core_vcn.this[each.value.vcn_key].default_security_list_id : lookup(local.sl_ids, n, null)
    ]
  )

  # route_table_id 는 여기서 지정하지 않는다 → route_tables.tf 의 oci_core_route_table_attachment
}
