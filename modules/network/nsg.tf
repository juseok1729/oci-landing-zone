# NSG 는 만들기만 합니다. VNIC(FortiGate/WAPPLES/LB 등) 연결은 그 리소스를 배포하는 쪽에서
# output nsg_ids 로 받아 nsg_ids 에 넣습니다.
resource "oci_core_network_security_group" "this" {
  for_each = local.nsg

  compartment_id = each.value.compartment_id
  vcn_id         = oci_core_vcn.this[each.value.vcn_key].id
  display_name   = each.value.display_name
  freeform_tags  = var.freeform_tags
}

# 규칙 키 = "<NSG>|<ingress|egress>|<순번>".
# shortcut: 중간에 규칙을 끼워 넣으면 뒤 순번 규칙이 재생성됨, 자주 바뀌면 규칙별 이름 키로 전환
resource "oci_core_network_security_group_security_rule" "this" {
  for_each = local.nsg_rules

  network_security_group_id = oci_core_network_security_group.this[each.value.owner].id
  direction                 = upper(each.value.dir)
  protocol                  = each.value.protocol
  stateless                 = each.value.stateless
  description               = each.value.description

  # 상대: CIDR | all-services / objectstorage | nsg:<같은 VCN 의 NSG 이름>
  source           = each.value.dir == "ingress" ? local.nsg_peer[each.key].value : null
  source_type      = each.value.dir == "ingress" ? local.nsg_peer[each.key].type : null
  destination      = each.value.dir == "egress" ? local.nsg_peer[each.key].value : null
  destination_type = each.value.dir == "egress" ? local.nsg_peer[each.key].type : null

  dynamic "tcp_options" {
    for_each = each.value.kind == "tcp" && (each.value.port_min != null || each.value.sport_min != null) ? [1] : []
    content {
      dynamic "destination_port_range" {
        for_each = each.value.port_min != null ? [1] : []
        content {
          min = each.value.port_min
          max = each.value.port_max
        }
      }
      dynamic "source_port_range" {
        for_each = each.value.sport_min != null ? [1] : []
        content {
          min = each.value.sport_min
          max = each.value.sport_max
        }
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.kind == "udp" && (each.value.port_min != null || each.value.sport_min != null) ? [1] : []
    content {
      dynamic "destination_port_range" {
        for_each = each.value.port_min != null ? [1] : []
        content {
          min = each.value.port_min
          max = each.value.port_max
        }
      }
      dynamic "source_port_range" {
        for_each = each.value.sport_min != null ? [1] : []
        content {
          min = each.value.sport_min
          max = each.value.sport_max
        }
      }
    }
  }

  dynamic "icmp_options" {
    for_each = each.value.kind == "icmp" && each.value.icmp_type != null ? [1] : []
    content {
      type = each.value.icmp_type
      code = each.value.icmp_code
    }
  }
}

locals {
  nsg_ids = { for k, n in oci_core_network_security_group.this : k => n.id }

  nsg_peer = {
    for k, r in local.nsg_rules : k => (
      startswith(r.cidr, "nsg:") ? { value = lookup(local.nsg_ids, trimprefix(r.cidr, "nsg:"), null), type = "NETWORK_SECURITY_GROUP" } :
      contains(keys(local.service_cidr), r.cidr) ? { value = local.service_cidr[r.cidr], type = "SERVICE_CIDR_BLOCK" } :
      { value = r.cidr, type = "CIDR_BLOCK" }
    )
  }
}
