terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

variable "tenancy_ocid" {
  type = string
}

variable "compartment_ids" {
  description = "compartment 이름 → OCID"
  type        = map(string)
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}

variable "buckets" {
  type = map(object({
    compartment  = string
    storage_tier = optional(string, "Standard")
    versioning   = optional(bool, false)
  }))
  default  = {}
  nullable = false
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "this" {
  for_each = var.buckets

  compartment_id = lookup(var.compartment_ids, each.value.compartment, each.value.compartment)
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = each.key
  access_type    = "NoPublicAccess"
  storage_tier   = each.value.storage_tier
  versioning     = each.value.versioning ? "Enabled" : "Disabled"
  freeform_tags  = var.freeform_tags
}

output "bucket_names" {
  value = { for k, b in oci_objectstorage_bucket.this : k => b.name }
}

output "config_errors" {
  value = concat(
    [
      for k, b in var.buckets : "bucket ${k}: compartment '${b.compartment}' 가 없습니다 (compartments.yaml 과 00-iam apply 확인)"
      if !contains(keys(var.compartment_ids), b.compartment) && !startswith(b.compartment, "ocid1.")
    ],
    [
      for k, b in var.buckets : "bucket ${k}: storage_tier 는 Standard 또는 Archive"
      if !contains(["Standard", "Archive"], b.storage_tier)
    ]
  )
}
