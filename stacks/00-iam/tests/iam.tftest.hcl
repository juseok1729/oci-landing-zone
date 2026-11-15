# OCI 자격증명 없이 도는 테스트:  terraform init -backend=false && terraform test   (또는 make test)

mock_provider "oci" {}
mock_provider "time" {}

variables {
  tenancy_ocid = "ocid1.tenancy.oc1..mock"
}

run "design_config_applies" {
  command = apply

  assert {
    condition     = length(output.compartment_ids) == 4
    error_message = "compartment 는 4개(HUB/PRD/DEV/MGMT)여야 합니다."
  }
}
