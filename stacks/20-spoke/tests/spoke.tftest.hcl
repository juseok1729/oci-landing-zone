# OCI 자격증명 없이 도는 테스트:  terraform init -backend=false && terraform test   (또는 make test)
#   test 는 default workspace 에서 돌기 때문에 var.vcn 으로 VCN 파일을 고른다.

mock_provider "oci" {
  mock_data "oci_objectstorage_namespace" {
    defaults = { namespace = "mocknamespace" }
  }
}

override_data {
  target = data.terraform_remote_state.iam
  values = {
    outputs = {
      compartment_ids = {
        HUB_COMP  = "ocid1.compartment.oc1..hub"
        PRD_COMP  = "ocid1.compartment.oc1..prd"
        DEV_COMP  = "ocid1.compartment.oc1..dev"
        MGMT_COMP = "ocid1.compartment.oc1..mgmt"
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.hub
  values = {
    outputs = {
      drg_ids             = { HUB_DRG = "ocid1.drg.oc1..hub" }
      drg_route_table_ids = { DRG_SPOKE_RT = "ocid1.drgroutetable.oc1..spoke", DRG_IPSEC_RT = "ocid1.drgroutetable.oc1..ipsec" }
    }
  }
}

variables {
  tenancy_ocid    = "ocid1.tenancy.oc1..mock"
  state_bucket    = "mock"
  state_namespace = "mock"
}

run "prd_applies" {
  command = apply

  variables {
    vcn = "prd"
  }

  assert {
    condition     = length(output.subnet_ids) == 5 && length(output.route_table_ids) == 1
    error_message = "PRD 는 subnet 5, route table 1 이어야 합니다."
  }
  assert {
    condition     = length(output.drg_attachment_ids) == 1 && length(output.bucket_names) == 1
    error_message = "PRD 는 attachment 1, bucket 1 이어야 합니다."
  }
  assert {
    condition     = length(output.nsg_ids) == 3
    error_message = "PRD 는 NSG 3(HQ_SSH/MYSQL_DB/CACHE) 이어야 합니다."
  }
}

run "dev_applies" {
  command = apply

  variables {
    vcn = "dev"
  }

  assert {
    condition     = length(output.subnet_ids) == 5 && length(output.route_table_ids) == 1
    error_message = "DEV 는 subnet 5, route table 1 이어야 합니다."
  }
  assert {
    condition     = length(output.drg_attachment_ids) == 1 && length(output.bucket_names) == 1
    error_message = "DEV 는 attachment 1, bucket 1 이어야 합니다."
  }
  assert {
    condition     = length(output.nsg_ids) == 3
    error_message = "DEV 는 NSG 3(HQ_SSH/MYSQL_DB/CACHE) 이어야 합니다."
  }
}

run "mgmt_applies" {
  command = apply

  variables {
    vcn = "mgmt"
  }

  assert {
    condition     = length(output.subnet_ids) == 6
    error_message = "MGMT 는 subnet 6 이어야 합니다."
  }
  assert {
    condition     = length(output.drg_attachment_ids) == 1 && length(output.bucket_names) == 3
    error_message = "MGMT 는 attachment 1, bucket 3 이어야 합니다."
  }
  assert {
    condition     = length(output.nsg_ids) == 5
    error_message = "MGMT 는 NSG 5(HQ_SSH + CI/CD 의 LB·VM, NSG→NSG 규칙 포함) 이어야 합니다."
  }
}

run "hub_file_rejected" {
  command = plan

  variables {
    vcn = "hub"
  }

  expect_failures = [
    terraform_data.config_check,
  ]
}

run "broken_config_rejected" {
  command = plan

  variables {
    vcn        = "prd"
    config_dir = "../../tests/fixtures/broken"
  }

  expect_failures = [
    terraform_data.config_check,
  ]
}
