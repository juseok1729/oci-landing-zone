#
# Route table 은 YAML 에 적힌 위치에 따라 3개 리소스 블록으로 나눈다 (locals.tf rt_all.kind).
#
#   RT(sgw)   ── service_gateways.<SGW>.route_table  target: drg / privateip  (OCI 제약)
#   RT(drga)  ── drg_attachment.route_table          target: sgw / privateip  (OCI 제약)
#   RT(subnet)── route_tables                        target: igw / sgw / drg / privateip
#
# 한 블록에 모두 넣으면  SGW → RT → (target)SGW  같은 순환이 생겨 plan 이 실패한다.
# subnet ↔ RT 연결은 oci_core_route_table_attachment 로 따로 하므로
# RT 가 같은 VCN 의 private IP(FortiGate 등)를 target 으로 써도 순환이 생기지 않는다.
#

# ── privateip:<IP> target 조회 ───────────────────────────────
data "oci_core_private_ips" "rt_target" {
  for_each = { for ref, p in local.pip : ref => p if p.subnet_key != null }

  ip_address = each.value.ip
  subnet_id  = oci_core_subnet.this[each.value.subnet_key].id

  lifecycle {
    postcondition {
      condition     = length(self.private_ips) > 0
      error_message = "route target privateip:${each.value.ip} 를 subnet ${each.value.subnet_key} 에서 찾지 못했습니다. 대상(FortiGate 등)을 먼저 배포하거나, 해당 rule 을 enabled: false 로 두세요."
    }
  }
}

locals {
  # target 문자열 → OCID.  (SGW 를 참조하지 않는 버전 / 참조하는 버전)
  target_ids_base = merge(
    { for k, g in oci_core_internet_gateway.this : "igw:${k}" => g.id },
    { for k, id in local.drg_ids : "drg:${k}" => id },
    { for ref, p in data.oci_core_private_ips.rt_target : "privateip:${ref}" => try(p.private_ips[0].id, null) }
  )
  target_ids_with_sgw = merge(
    local.target_ids_base,
    { for k, g in oci_core_service_gateway.this : "sgw:${k}" => g.id }
  )

  # rule → OCI route_rules 형태
  #   privateip 는 "privateip:<IP>@<VCN>" 키로 찾음
  rt_sgw_rules = {
    for k, r in local.rt_sgw : k => [
      for rule in r.rules : {
        destination      = lookup(local.service_cidr, rule.destination, rule.destination)
        destination_type = contains(keys(local.service_cidr), rule.destination) ? "SERVICE_CIDR_BLOCK" : "CIDR_BLOCK"
        description      = rule.description
        network_entity_id = (
          startswith(rule.target, "ocid1.")
          ? rule.target
          : lookup(local.target_ids_base, startswith(rule.target, "privateip:") ? "${rule.target}@${r.vcn_key}" : rule.target, null)
        )
      }
    ]
  }

  rt_other_rules = {
    for k, r in merge(local.rt_drga, local.rt_subnet) : k => [
      for rule in r.rules : {
        destination      = lookup(local.service_cidr, rule.destination, rule.destination)
        destination_type = contains(keys(local.service_cidr), rule.destination) ? "SERVICE_CIDR_BLOCK" : "CIDR_BLOCK"
        description      = rule.description
        network_entity_id = (
          startswith(rule.target, "ocid1.")
          ? rule.target
          : lookup(local.target_ids_with_sgw, startswith(rule.target, "privateip:") ? "${rule.target}@${r.vcn_key}" : rule.target, null)
        )
      }
    ]
  }
}

# ── 1) Service Gateway 용 ────────────────────────────────────
resource "oci_core_route_table" "sgw" {
  for_each = local.rt_sgw

  compartment_id = each.value.compartment_id
  vcn_id         = oci_core_vcn.this[each.value.vcn_key].id
  display_name   = each.value.display_name
  freeform_tags  = var.freeform_tags

  dynamic "route_rules" {
    for_each = local.rt_sgw_rules[each.key]
    content {
      destination       = route_rules.value.destination
      destination_type  = route_rules.value.destination_type
      network_entity_id = route_rules.value.network_entity_id
      description       = route_rules.value.description
    }
  }
}

# ── 2) DRG attachment(VCN ingress) 용 ────────────────────────
resource "oci_core_route_table" "drga" {
  for_each = local.rt_drga

  compartment_id = each.value.compartment_id
  vcn_id         = oci_core_vcn.this[each.value.vcn_key].id
  display_name   = each.value.display_name
  freeform_tags  = var.freeform_tags

  dynamic "route_rules" {
    for_each = local.rt_other_rules[each.key]
    content {
      destination       = route_rules.value.destination
      destination_type  = route_rules.value.destination_type
      network_entity_id = route_rules.value.network_entity_id
      description       = route_rules.value.description
    }
  }
}

# ── 3) Subnet 용 ─────────────────────────────────────────────
resource "oci_core_route_table" "subnet" {
  for_each = local.rt_subnet

  compartment_id = each.value.compartment_id
  vcn_id         = oci_core_vcn.this[each.value.vcn_key].id
  display_name   = each.value.display_name
  freeform_tags  = var.freeform_tags

  dynamic "route_rules" {
    for_each = local.rt_other_rules[each.key]
    content {
      destination       = route_rules.value.destination
      destination_type  = route_rules.value.destination_type
      network_entity_id = route_rules.value.network_entity_id
      description       = route_rules.value.description
    }
  }

  # DRG 로 보내는 rule 은 VCN 이 DRG 에 attach 된 뒤에 만들도록
  depends_on = [oci_core_drg_attachment.this]
}

locals {
  rt_sgw_ids    = { for k, r in oci_core_route_table.sgw : k => r.id }
  rt_drga_ids   = { for k, r in oci_core_route_table.drga : k => r.id }
  rt_subnet_ids = { for k, r in oci_core_route_table.subnet : k => r.id }

  rt_ids = merge(local.rt_sgw_ids, local.rt_drga_ids, local.rt_subnet_ids)
}

# ── subnet ↔ route table 연결 ────────────────────────────────
# route_table 을 지정하지 않은(default) subnet 은 VCN 기본 route table 사용
resource "oci_core_route_table_attachment" "this" {
  for_each = { for sk, s in local.subnet : sk => s if s.route_table != null }

  subnet_id      = oci_core_subnet.this[each.key].id
  route_table_id = lookup(local.rt_ids, each.value.route_table, null)
}
