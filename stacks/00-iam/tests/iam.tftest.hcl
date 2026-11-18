# OCI 자격증명 없이 도는 테스트:  terraform init -backend=false && terraform test   (또는 make test)

mock_provider "oci" {}
mock_provider "time" {}

variables {
  tenancy_ocid = "ocid1.tenancy.oc1..mock"
}

run "design_config_applies" {
  command = apply

  assert {
    condition     = sort(keys(output.compartment_ids)) == sort(keys(yamldecode(file("../../config/compartments.yaml")).compartments))
    error_message = "compartments.yaml 의 compartment 가 모두 만들어져야 합니다: ${join(", ", keys(output.compartment_ids))}"
  }
}
