output "vcn_ids" {
  value = { for k, v in oci_core_vcn.this : k => v.id }
}

output "subnet_ids" {
  value = { for k, s in oci_core_subnet.this : k => s.id }
}

output "route_table_ids" {
  value = local.rt_ids
}

output "security_list_ids" {
  value = local.sl_ids
}

output "nsg_ids" {
  description = "NSG 이름 → OCID (인스턴스/LB 배포 시 nsg_ids 로 사용)"
  value       = local.nsg_ids
}

output "gateway_ids" {
  value = merge(
    { for k, g in oci_core_internet_gateway.this : k => g.id },
    { for k, g in oci_core_service_gateway.this : k => g.id }
  )
}

output "drg_ids" {
  value = local.drg_ids
}

output "drg_route_table_ids" {
  value = local.drg_rt_ids
}

output "drg_attachment_ids" {
  value = local.drga_ids
}

output "config_errors" {
  description = "YAML 정합성 오류 목록 (비어 있어야 정상)"
  value       = local.config_errors
}

output "rule_destinations" {
  description = "route table 이름 → 실제로 들어가는 destination 목록 (spokes 펼침 · enabled: auto 확인용)"
  value = {
    vcn = { for k, rules in merge(local.rt_sgw_rules, local.rt_other_rules) : k => [for x in rules : x.destination] }
    drg = { for k, _ in local.drg_rt : k => sort([for x in values(local.drg_rt_rules) : x.destination if x.rt_key == k]) }
  }
}
