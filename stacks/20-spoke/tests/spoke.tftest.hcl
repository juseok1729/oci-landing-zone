# OCI 자격증명 없이 도는 테스트:  terraform init -backend=false && terraform test   (또는 make test)
#   test 는 default workspace 에서 돌기 때문에 var.vcn 으로 VCN 파일을 고른다.

mock_provider "oci" {
  # SGW 의 all-services 를 service id, CIDR label 로 바꾸는 데 쓴다
  mock_data "oci_core_services" {
    defaults = {
      services = [
        { id = "ocid1.service.oc1.ap-seoul-1.mockall", name = "All ICN Services In Oracle Services Network", cidr_block = "all-icn-services-in-oracle-services-network", description = "mock" }
      ]
    }
  }
}

override_data {
  target = data.terraform_remote_state.iam
  values = {
    outputs = {
      # config/compartments.yaml 의 이름 그대로 (+ tests/fixtures 전용 TEST_COMP). compartment 를 바꿔도 테스트는 안 고친다
      compartment_ids = merge(
        { TEST_COMP = "ocid1.compartment.oc1..test" },
        { for k, _ in yamldecode(file("../../config/compartments.yaml")).compartments : k => "ocid1.compartment.oc1..${lower(k)}" }
      )
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

run "ec_prd_applies" {
  command = apply

  variables {
    vcn = "ec-prd"
  }

  assert {
    condition     = length(output.subnet_ids) == 5 && length(output.route_table_ids) == 1
    error_message = "ec-prd 는 subnet 5, route table 1 이어야 합니다."
  }
  assert {
    condition     = length(output.drg_attachment_ids) == 1
    error_message = "ec-prd 는 attachment 1 이어야 합니다."
  }
  assert {
    condition     = keys(output.gateway_ids) == ["EC_PRD_SGW"] && contains(output.rule_destinations.vcn["EC_PRD_RT"], "all-icn-services-in-oracle-services-network")
    error_message = "ec-prd 는 자기 SGW(EC_PRD_SGW) 하나를 갖고, EC_PRD_RT 가 OCI 서비스를 그 SGW 로 보내야 합니다."
  }
  assert {
    condition     = length(output.nsg_ids) == 3
    error_message = "ec-prd 는 NSG 3(HQ_SSH/MYSQL_DB/CACHE) 이어야 합니다."
  }
}

run "ec_dev_applies" {
  command = apply

  variables {
    vcn = "ec-dev"
  }

  assert {
    condition     = length(output.subnet_ids) == 5 && length(output.route_table_ids) == 1
    error_message = "ec-dev 는 subnet 5, route table 1 이어야 합니다."
  }
  assert {
    condition     = length(output.drg_attachment_ids) == 1
    error_message = "ec-dev 는 attachment 1 이어야 합니다."
  }
  assert {
    condition     = keys(output.gateway_ids) == ["EC_DEV_SGW"] && contains(output.rule_destinations.vcn["EC_DEV_RT"], "all-icn-services-in-oracle-services-network")
    error_message = "ec-dev 는 자기 SGW(EC_DEV_SGW) 하나를 갖고, EC_DEV_RT 가 OCI 서비스를 그 SGW 로 보내야 합니다."
  }
  assert {
    condition     = length(output.nsg_ids) == 3
    error_message = "ec-dev 는 NSG 3(HQ_SSH/MYSQL_DB/CACHE) 이어야 합니다."
  }
}

run "erp_prd_applies" {
  command = apply

  variables {
    vcn = "erp-prd"
  }

  assert {
    condition     = length(output.subnet_ids) == 5 && length(output.route_table_ids) == 1
    error_message = "erp-prd 는 subnet 5, route table 1 이어야 합니다."
  }
  assert {
    condition     = length(output.drg_attachment_ids) == 1
    error_message = "erp-prd 는 attachment 1 이어야 합니다."
  }
  assert {
    condition     = keys(output.gateway_ids) == ["ERP_PRD_SGW"] && contains(output.rule_destinations.vcn["ERP_PRD_RT"], "all-icn-services-in-oracle-services-network")
    error_message = "erp-prd 는 자기 SGW(ERP_PRD_SGW) 하나를 갖고, ERP_PRD_RT 가 OCI 서비스를 그 SGW 로 보내야 합니다."
  }
  assert {
    condition     = length(output.nsg_ids) == 3
    error_message = "erp-prd 는 NSG 3(HQ_SSH/MYSQL_DB/CACHE) 이어야 합니다."
  }
}

run "erp_dev_applies" {
  command = apply

  variables {
    vcn = "erp-dev"
  }

  assert {
    condition     = length(output.subnet_ids) == 5 && length(output.route_table_ids) == 1
    error_message = "erp-dev 는 subnet 5, route table 1 이어야 합니다."
  }
  assert {
    condition     = length(output.drg_attachment_ids) == 1
    error_message = "erp-dev 는 attachment 1 이어야 합니다."
  }
  assert {
    condition     = keys(output.gateway_ids) == ["ERP_DEV_SGW"] && contains(output.rule_destinations.vcn["ERP_DEV_RT"], "all-icn-services-in-oracle-services-network")
    error_message = "erp-dev 는 자기 SGW(ERP_DEV_SGW) 하나를 갖고, ERP_DEV_RT 가 OCI 서비스를 그 SGW 로 보내야 합니다."
  }
  assert {
    condition     = length(output.nsg_ids) == 3
    error_message = "erp-dev 는 NSG 3(HQ_SSH/MYSQL_DB/CACHE) 이어야 합니다."
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
    condition     = length(output.drg_attachment_ids) == 1
    error_message = "MGMT 는 attachment 1 이어야 합니다."
  }
  assert {
    condition     = keys(output.gateway_ids) == ["MGMT_SGW"] && contains(output.rule_destinations.vcn["MGMT_RT"], "all-icn-services-in-oracle-services-network")
    error_message = "MGMT 는 자기 SGW(MGMT_SGW) 하나를 갖고, MGMT_RT 가 OCI 서비스를 그 SGW 로 보내야 합니다."
  }
  assert {
    condition     = length(output.nsg_ids) == 5
    error_message = "MGMT 는 NSG 5(HQ_SSH + CI/CD 의 LB, VM, NSG→NSG 규칙 포함) 이어야 합니다."
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

run "spokes_alias_excludes_self" {
  command = apply

  variables {
    vcn        = "a"
    config_dir = "../../tests/fixtures/spokes"
  }

  assert {
    condition     = join(",", output.rule_destinations.vcn["A_RT"]) == "10.2.0.0/16,10.3.0.0/16"
    error_message = "A_RT 의 spokes 는 자기 CIDR(10.1)을 빼고 B 의 2개로 펼쳐져야 합니다: ${join(",", output.rule_destinations.vcn["A_RT"])}"
  }
}

# hub 를 apply 하기 전(빈 state): Unsupported attribute 대신 config_check 의 안내 메시지로 멈춰야 한다
run "hub_not_applied" {
  command = plan

  variables {
    vcn = "ec-prd"
  }

  override_data {
    target = data.terraform_remote_state.hub
    values = { outputs = {} }
  }

  expect_failures = [
    terraform_data.config_check,
  ]
}
