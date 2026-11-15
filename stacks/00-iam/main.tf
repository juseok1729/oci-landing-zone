#
# 00-iam : compartment (홈 리전).  다른 stack 은 이 state 의 compartment_ids 를 읽는다.
#
terraform {
  required_version = "~> 1.12"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }

  # bucket / namespace / region 은 backend.hcl 로 주입 (key 는 여기 고정. N.B. backend.hcl 에 key 를 넣지 않는다)
  backend "oci" {
    key = "lz/iam.tfstate"
  }
}

# IAM(Compartment)은 홈 리전에서만 생성 가능
provider "oci" {
  region              = coalesce(var.home_region, var.region)
  auth                = var.oci_auth
  config_file_profile = var.oci_config_profile
}

module "config" {
  source     = "../../modules/config"
  config_dir = var.config_dir
}

module "compartments" {
  source = "../../modules/compartments"

  tenancy_ocid  = var.tenancy_ocid
  parent_ocid   = module.config.compartments.parent_ocid
  compartments  = module.config.compartments.compartments
  freeform_tags = { ManagedBy = "terraform", Stack = "iam" }
}

resource "terraform_data" "config_check" {
  lifecycle {
    precondition {
      condition     = length(module.config.errors.compartments) == 0
      error_message = "config/ YAML 오류 ${length(module.config.errors.compartments)}건\n  - ${join("\n  - ", module.config.errors.compartments)}"
    }
  }
}

output "compartment_ids" {
  description = "compartment 이름 → OCID"
  value       = module.compartments.ids
}
