#
# 20-spoke : spoke VCN 1개 (bucket 은 hub stack 이 만든다).  workspace 이름 = config/vcns/<파일> 이름
#   terraform workspace select prd   →  config/vcns/prd.yaml  (state 도 workspace 별로 분리)
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
  # workspace 별 state 위치: tf-state-env/<workspace>/lz/spoke.tfstate
  backend "oci" {
    key = "lz/spoke.tfstate"
  }
}

provider "oci" {
  region              = var.region
  auth                = var.oci_auth
  config_file_profile = var.oci_config_profile
}

locals {
  # default workspace 는 terraform test 전용 (var.vcn). 실제 실행은 workspace 가 VCN 을 정한다.
  vcn_file = terraform.workspace == "default" ? var.vcn : terraform.workspace

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

data "terraform_remote_state" "hub" {
  backend = "oci"
  config  = merge(local.state_config, { key = "lz/hub.tfstate" })
}

module "config" {
  source     = "../../modules/config"
  config_dir = var.config_dir
}

locals {
  spoke_files = [for f in keys(module.config.vcn_files) : f if f != "hub"]
  vcn_file_ok = contains(local.spoke_files, coalesce(local.vcn_file, "-"))
  vcns        = try(module.config.vcn_files[local.vcn_file_ok ? local.vcn_file : "-"], {})
  # 앞 stack(iam, hub) 이 비어 있으면 Unsupported attribute 로 죽지 않고 config_check 의 안내 메시지로 멈춘다
  iam_ready       = can(data.terraform_remote_state.iam.outputs.compartment_ids)
  hub_ready       = can(data.terraform_remote_state.hub.outputs.drg_ids)
  compartment_ids = try(data.terraform_remote_state.iam.outputs.compartment_ids, {})

  # route rule 의 destination: spokes → spoke VCN CIDR 전체 (자기 VCN 것은 network module 이 뺀다)
  spoke_cidrs = sort(flatten([for f in local.spoke_files : [for v in values(module.config.vcn_files[f]) : try(v.cidrs, [])]]))

  tags = { ManagedBy = "terraform", Stack = coalesce(local.vcn_file, "-") }
}

module "network" {
  source = "../../modules/network"

  compartment_ids              = local.compartment_ids
  spoke_cidrs                  = local.spoke_cidrs
  vcns                         = local.hub_ready ? local.vcns : {} # DRG 가 없으면 attachment, route 를 계획할 수 없다
  external_drg_ids             = try(data.terraform_remote_state.hub.outputs.drg_ids, {})
  external_drg_route_table_ids = try(data.terraform_remote_state.hub.outputs.drg_route_table_ids, {})
  freeform_tags                = local.tags
}

locals {
  config_errors = concat(
    local.iam_ready ? [] : ["iam stack 이 아직 apply 되지 않았습니다: make apply-iam 을 먼저 실행하세요"],
    local.hub_ready ? [] : ["hub stack 이 아직 apply 되지 않았습니다: make apply-hub 를 먼저 실행하세요"],
    local.vcn_file_ok ? [] : ["workspace 를 spoke VCN 파일 이름(${join(" / ", local.spoke_files)})으로 선택하세요: terraform workspace select <이름> (지금: ${terraform.workspace})"],
    local.vcn_file_ok ? module.config.errors.vcns[local.vcn_file] : [],
    module.config.errors.cross,
    module.network.config_errors
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
  value = module.network.subnet_ids
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

output "drg_attachment_ids" {
  value = module.network.drg_attachment_ids
}

output "rule_destinations" {
  description = "route table 이름 → 펼친 destination 목록 (spokes 확인용)"
  value       = module.network.rule_destinations
}
