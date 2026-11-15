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
