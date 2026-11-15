#
# 10-hub : DRG(+ DRG route table) · HUB_VCN(config/vcns/hub.yaml) · spoke 에 속하지 않은 bucket
#   spoke stack 은 이 state 의 drg_ids / drg_route_table_ids 를 읽어 DRG 에 attach 한다.
#
terraform {
  required_version = "~> 1.12"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
  }

  # bucket / namespace / region 은 backend.hcl 로 주입 (key 는 여기 고정. N.B. backend.hcl 에 key 를 넣지 않는다)
  backend "oci" {
    key = "lz/hub.tfstate"
  }
}

provider "oci" {
  region              = var.region
  auth                = var.oci_auth
  config_file_profile = var.oci_config_profile
}

locals {
  vcn_file = "hub"

  # terraform_remote_state 의 oci backend 는 auth 값을 APIKey 로 씀 (provider 는 ApiKey)
  state_config = {
    bucket              = var.state_bucket
    namespace           = var.state_namespace
    region              = coalesce(var.state_region, var.region)
    auth                = var.oci_auth == "ApiKey" ? "APIKey" : var.oci_auth
    config_file_profile = var.oci_config_profile
  }
}

data "terraform_remote_state" "iam" {
  backend = "oci"
  config  = merge(local.state_config, { key = "lz/iam.tfstate" })
}

module "config" {
  source     = "../../modules/config"
  config_dir = var.config_dir
}

locals {
  compartment_ids = data.terraform_remote_state.iam.outputs.compartment_ids

  # spoke VCN 의 compartment 에 속한 bucket 은 그 spoke stack 이, 나머지는 hub 가 만든다
  spoke_compartments = distinct(flatten([
    for f, d in module.config.vcn_files : [for v in values(d) : try(v.compartment, "")] if f != local.vcn_file
  ]))
  buckets = try({ for k, b in module.config.buckets : k => b if !contains(local.spoke_compartments, try(b.compartment, "")) }, null)

  tags = { ManagedBy = "terraform", Stack = "hub" }
}

module "network" {
  source = "../../modules/network"

  compartment_ids = local.compartment_ids
  vcns            = try(module.config.vcn_files[local.vcn_file], {})
  drgs            = module.config.drgs
  freeform_tags   = local.tags
}

module "buckets" {
  source = "../../modules/buckets"

  tenancy_ocid    = var.tenancy_ocid
  compartment_ids = local.compartment_ids
  buckets         = local.buckets
  freeform_tags   = local.tags
}

locals {
  config_errors = concat(
    contains(keys(module.config.vcn_files), local.vcn_file) ? [] : ["config/vcns/${local.vcn_file}.yaml 이 없습니다"],
    module.config.errors.drg,
    module.config.errors.buckets,
    try(module.config.errors.vcns[local.vcn_file], []),
    module.config.errors.cross,
    module.network.config_errors,
    module.buckets.config_errors
  )
}

resource "terraform_data" "config_check" {
  lifecycle {
    precondition {
      condition     = length(local.config_errors) == 0
      error_message = "config/ YAML 오류 ${length(local.config_errors)}건\n  - ${join("\n  - ", local.config_errors)}"
    }
  }
}

output "vcn_ids" {
  value = module.network.vcn_ids
}

output "subnet_ids" {
  description = "subnet 이름 → OCID (FortiGate/WAPPLES/인스턴스 배포 시 참조)"
  value       = module.network.subnet_ids
}

output "route_table_ids" {
  value = module.network.route_table_ids
}

output "security_list_ids" {
  value = module.network.security_list_ids
}

output "nsg_ids" {
  value = module.network.nsg_ids
}

output "gateway_ids" {
  value = module.network.gateway_ids
}

output "drg_ids" {
  description = "spoke stack 이 읽음"
  value       = module.network.drg_ids
}

output "drg_route_table_ids" {
  description = "spoke stack 이 읽음"
  value       = module.network.drg_route_table_ids
}

output "drg_attachment_ids" {
  value = module.network.drg_attachment_ids
}

output "bucket_names" {
  value = module.buckets.bucket_names
}
