#
# config/ YAML 을 읽고 "알 수 없는 키(오타)" 를 찾는다. 리소스는 만들지 않는다.
#  - Terraform 은 타입에 없는 키를 조용히 버리므로, 키 이름 검사는 여기서 한다.
#  - 값의 정합성(CIDR 범위, 참조 등)은 각 리소스 모듈의 config_errors 가 담당한다.
#  - 오류는 파일별로 돌려주므로, stack 은 자기와 관련된 파일 오류만 본다.
#

variable "config_dir" {
  description = "config 디렉터리 경로"
  type        = string
}

locals {
  dir = var.config_dir

  compartments_raw = fileexists("${local.dir}/compartments.yaml") ? yamldecode(file("${local.dir}/compartments.yaml")) : null
  drg_raw          = fileexists("${local.dir}/drg.yaml") ? yamldecode(file("${local.dir}/drg.yaml")) : null
  buckets_raw      = fileexists("${local.dir}/buckets.yaml") ? yamldecode(file("${local.dir}/buckets.yaml")) : null
  nvas_raw         = fileexists("${local.dir}/nvas.yaml") ? yamldecode(file("${local.dir}/nvas.yaml")) : null

  # config/vcns/<이름>.yaml → { "<이름>" = { VCN_NAME = {...} } }   (파일 1개 = VCN 1개 = stack 1개)
  vcn_files = {
    for f in fileset("${local.dir}/vcns", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.dir}/vcns/${f}"))
    if yamldecode(file("${local.dir}/vcns/${f}")) != null
  }

  # 새 키를 추가하면 modules/network/variables.tf 타입에도 추가한다.
  allowed = {
    compartments_file = ["parent_ocid", "compartments"]
    compartment       = ["description", "ocid"]
    drg_file          = ["drgs"]
    drg               = ["compartment", "display_name", "route_tables"]
    drg_route_table   = ["display_name", "rules"]
    drg_rule          = ["destination", "destinations", "next_hop", "enabled"]
    buckets_file      = ["buckets"]
    bucket            = ["compartment", "storage_tier", "versioning"]
    nvas_file         = ["nvas"]
    nva               = ["compartment", "display_name", "image", "shape", "ocpus", "memory_gb", "availability_domain", "vnics"]
    nva_vnic          = ["name", "subnet", "private_ip", "secondary_ips", "skip_source_dest_check", "public_ip"]
    vcn               = ["compartment", "display_name", "cidrs", "dns_label", "lock_default_security_list", "internet_gateways", "service_gateways", "drg_attachment", "route_tables", "security_lists", "network_security_groups", "subnets"]
    igw               = ["display_name", "compartment", "enabled"]
    sgw               = ["display_name", "compartment", "services", "route_table"]
    drg_attachment    = ["name", "drg", "route_table", "drg_route_table"]
    gw_route_table    = ["name", "display_name", "compartment", "rules"]
    route_table       = ["display_name", "compartment", "rules"]
    route_rule        = ["destination", "destinations", "target", "description", "enabled"]
    fw_owner          = ["display_name", "compartment", "ingress", "egress"]
    fw_ingress        = ["source", "protocol", "port", "source_port", "icmp_type", "icmp_code", "stateless", "description"]
    fw_egress         = ["destination", "protocol", "port", "source_port", "icmp_type", "icmp_code", "stateless", "description"]
    subnet            = ["cidr", "display_name", "public", "route_table", "security_lists", "dns_label", "compartment"]
  }

  # 검사 대상 목록: { where, obj, kind }.  obj 의 키가 allowed[kind] 안에 있어야 함
  checks_compartments = concat(
    [{ where = "compartments.yaml", obj = local.compartments_raw, kind = "compartments_file" }],
    [for c in try(keys(local.compartments_raw.compartments), []) : { where = "compartments.yaml > ${c}", obj = local.compartments_raw.compartments[c], kind = "compartment" }]
  )

  checks_drg = concat(
    [{ where = "drg.yaml", obj = local.drg_raw, kind = "drg_file" }],
    flatten([
      for d in try(keys(local.drg_raw.drgs), []) : concat(
        [{ where = "drg.yaml > ${d}", obj = local.drg_raw.drgs[d], kind = "drg" }],
        flatten([
          for rt in try(keys(local.drg_raw.drgs[d].route_tables), []) : concat(
            [{ where = "drg.yaml > ${d}.route_tables.${rt}", obj = local.drg_raw.drgs[d].route_tables[rt], kind = "drg_route_table" }],
            [for i, r in try(local.drg_raw.drgs[d].route_tables[rt].rules, []) : { where = "drg.yaml > ${d}.route_tables.${rt}.rules[${i}]", obj = r, kind = "drg_rule" }]
          )
        ])
      )
    ])
  )

  checks_buckets = concat(
    [{ where = "buckets.yaml", obj = local.buckets_raw, kind = "buckets_file" }],
    [for b in try(keys(local.buckets_raw.buckets), []) : { where = "buckets.yaml > ${b}", obj = local.buckets_raw.buckets[b], kind = "bucket" }]
  )

  checks_nvas = concat(
    [{ where = "nvas.yaml", obj = local.nvas_raw, kind = "nvas_file" }],
    flatten([
      for n in try(keys(local.nvas_raw.nvas), []) : concat(
        [{ where = "nvas.yaml > ${n}", obj = local.nvas_raw.nvas[n], kind = "nva" }],
        [for i, v in try(local.nvas_raw.nvas[n].vnics, []) : { where = "nvas.yaml > ${n}.vnics[${i}]", obj = v, kind = "nva_vnic" }]
      )
    ])
  )

  checks_vcns = {
    for f, doc in local.vcn_files : f => flatten([
      for vn, v in doc : concat(
        [{ where = "vcns/${f}.yaml > ${vn}", obj = v, kind = "vcn" }],

        [for k in try(keys(v.internet_gateways), []) : { where = "vcns/${f}.yaml > ${vn}.internet_gateways.${k}", obj = v.internet_gateways[k], kind = "igw" }],

        flatten([
          for k in try(keys(v.service_gateways), []) : concat(
            [{ where = "vcns/${f}.yaml > ${vn}.service_gateways.${k}", obj = v.service_gateways[k], kind = "sgw" }],
            try(v.service_gateways[k].route_table, null) == null ? [] : [{ where = "vcns/${f}.yaml > ${vn}.service_gateways.${k}.route_table", obj = v.service_gateways[k].route_table, kind = "gw_route_table" }],
            [for i, r in try(v.service_gateways[k].route_table.rules, []) : { where = "vcns/${f}.yaml > ${vn}.service_gateways.${k}.route_table.rules[${i}]", obj = r, kind = "route_rule" }]
          )
        ]),

        try(v.drg_attachment, null) == null ? [] : [{ where = "vcns/${f}.yaml > ${vn}.drg_attachment", obj = v.drg_attachment, kind = "drg_attachment" }],
        try(v.drg_attachment.route_table, null) == null ? [] : [{ where = "vcns/${f}.yaml > ${vn}.drg_attachment.route_table", obj = v.drg_attachment.route_table, kind = "gw_route_table" }],
        [for i, r in try(v.drg_attachment.route_table.rules, []) : { where = "vcns/${f}.yaml > ${vn}.drg_attachment.route_table.rules[${i}]", obj = r, kind = "route_rule" }],

        flatten([
          for k in try(keys(v.route_tables), []) : concat(
            [{ where = "vcns/${f}.yaml > ${vn}.route_tables.${k}", obj = v.route_tables[k], kind = "route_table" }],
            [for i, r in try(v.route_tables[k].rules, []) : { where = "vcns/${f}.yaml > ${vn}.route_tables.${k}.rules[${i}]", obj = r, kind = "route_rule" }]
          )
        ]),

        flatten([
          for sec in ["security_lists", "network_security_groups"] : [
            for k in try(keys(v[sec]), []) : concat(
              [{ where = "vcns/${f}.yaml > ${vn}.${sec}.${k}", obj = v[sec][k], kind = "fw_owner" }],
              [for i, r in try(v[sec][k].ingress, []) : { where = "vcns/${f}.yaml > ${vn}.${sec}.${k}.ingress[${i}]", obj = r, kind = "fw_ingress" }],
              [for i, r in try(v[sec][k].egress, []) : { where = "vcns/${f}.yaml > ${vn}.${sec}.${k}.egress[${i}]", obj = r, kind = "fw_egress" }]
            )
          ]
        ]),

        [for k in try(keys(v.subnets), []) : { where = "vcns/${f}.yaml > ${vn}.subnets.${k}", obj = v.subnets[k], kind = "subnet" }]
      )
    ])
  }

  # 같은 VCN 이름이 여러 파일에 있으면 안 됨
  vcn_names_all = flatten([for d in values(local.vcn_files) : keys(d)])
  errors_cross = concat(
    [
      for n in distinct(local.vcn_names_all) : "config/vcns: VCN '${n}' 이 여러 파일에 중복 정의됨"
      if length([for x in local.vcn_names_all : x if x == n]) > 1
    ],
    [for f, d in local.vcn_files : "config/vcns/${f}.yaml: VCN 은 파일당 1개만 (지금 ${length(d)}개)" if length(d) != 1]
  )
}

output "compartments" {
  value = {
    parent_ocid  = try(local.compartments_raw.parent_ocid, null)
    compartments = try(local.compartments_raw.compartments, null)
  }
}

output "drgs" {
  value = try(local.drg_raw.drgs, null)
}

output "buckets" {
  value = try(local.buckets_raw.buckets, null)
}

output "nvas" {
  value = try(local.nvas_raw.nvas, null)
}

output "vcn_files" {
  description = "파일 이름(확장자 제외) → 그 파일의 VCN"
  value       = local.vcn_files
}

output "errors" {
  description = "파일별 알 수 없는 키 오류"
  value = {
    compartments = flatten([for c in local.checks_compartments : [for k in try(keys(c.obj), []) : "${c.where}: 알 수 없는 키 '${k}'" if !contains(local.allowed[c.kind], k)]])
    drg          = flatten([for c in local.checks_drg : [for k in try(keys(c.obj), []) : "${c.where}: 알 수 없는 키 '${k}'" if !contains(local.allowed[c.kind], k)]])
    buckets      = flatten([for c in local.checks_buckets : [for k in try(keys(c.obj), []) : "${c.where}: 알 수 없는 키 '${k}'" if !contains(local.allowed[c.kind], k)]])
    nvas         = flatten([for c in local.checks_nvas : [for k in try(keys(c.obj), []) : "${c.where}: 알 수 없는 키 '${k}'" if !contains(local.allowed[c.kind], k)]])
    vcns         = { for f, cs in local.checks_vcns : f => flatten([for c in cs : [for k in try(keys(c.obj), []) : "${c.where}: 알 수 없는 키 '${k}'" if !contains(local.allowed[c.kind], k)]]) }
    cross        = local.errors_cross
  }
}
