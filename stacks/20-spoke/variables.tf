# 모든 stack 이 같은 변수 세트를 쓴다 (terraform.tfvars 하나를 같이 쓰기 위해). 바꾸면 모든 stack 의 variables.tf 를 바꾼다.

variable "tenancy_ocid" {
  description = "Tenancy OCID"
  type        = string
}

variable "region" {
  description = "리소스를 만들 리전"
  type        = string
  default     = "ap-seoul-1"
}

variable "home_region" {
  description = "Tenancy 홈 리전 (IAM 생성용). 비우면 region 과 같다고 봄"
  type        = string
  default     = null
}

variable "oci_auth" {
  description = "ApiKey | SecurityToken | InstancePrincipal"
  type        = string
  default     = "ApiKey"
}

variable "oci_config_profile" {
  description = "~/.oci/config 프로파일 이름 (ApiKey/SecurityToken 일 때)"
  type        = string
  default     = "DEFAULT"
}

variable "state_bucket" {
  description = "state 버킷 이름 (backend.hcl 의 bucket 과 같게). 다른 stack 의 output 을 읽을 때 사용"
  type        = string
  default     = null
}

variable "state_namespace" {
  description = "state 버킷의 Object Storage namespace (backend.hcl 의 namespace 와 같게)"
  type        = string
  default     = null
}

variable "state_region" {
  description = "state 버킷 리전. 비우면 region"
  type        = string
  default     = null
}

variable "config_dir" {
  description = "YAML 설정 디렉터리 (stack 디렉터리 기준)"
  type        = string
  default     = "../../config"
}

variable "vcn" {
  description = "default workspace 에서만 쓰는 VCN 파일 이름 (terraform test 용). 평소에는 workspace(prd/dev/mgmt)가 정합니다"
  type        = string
  default     = null
}
