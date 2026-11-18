# 실행 순서: iam → hub → spoke(prd/dev/mgmt).  예) make plan-prd / make apply-hub / make apply-all / make destroy-all
#   terraform.tfvars 와 backend.hcl 은 repo 루트에 둔다 (*.example 복사).

TF     ?= terraform
# config/vcns 의 hub 외 파일이 곧 spoke (파일만 추가하면 make apply-<이름> 이 된다)
SPOKES := $(filter-out hub,$(basename $(notdir $(wildcard config/vcns/*.yaml))))
VARS   := -var-file=$(CURDIR)/terraform.tfvars

# stack 이름 → 디렉터리 (spoke 는 20-spoke 하나를 workspace 로 나눠 씀)
stack_dir = $(if $(filter iam,$1),stacks/00-iam,$(if $(filter hub,$1),stacks/10-hub,stacks/20-spoke))
ws  = $(if $(filter $(SPOKES),$1),$(TF) -chdir=stacks/20-spoke workspace select -or-create $1 &&,)

.PHONY: init test fmt apply-all destroy-all

init:
	for d in 00-iam 10-hub 20-spoke; do $(TF) -chdir=stacks/$$d init -backend-config=$(CURDIR)/backend.hcl || exit 1; done

plan-%:
	$(call ws,$*) $(TF) -chdir=$(call stack_dir,$*) plan $(VARS)

apply-%:
	$(call ws,$*) $(TF) -chdir=$(call stack_dir,$*) apply $(VARS)

apply-all: apply-iam apply-hub $(addprefix apply-,$(SPOKES))

destroy-%:
	$(call ws,$*) $(TF) -chdir=$(call stack_dir,$*) destroy $(VARS)

# 만든 순서의 역순. iam 은 compartment 를 state 에서만 빼고 실제로는 남김 (enable_delete = false)
destroy-all: $(addprefix destroy-,$(SPOKES)) destroy-hub destroy-iam

# OCI 자격증명 없이 (mock provider). 백엔드 초기화와 별개로 돌릴 수 있다.
# TF_WORKSPACE=default: 실제 apply 후 선택돼 있는 spoke workspace(prd 등)를 test 가 따라가지 않게 (선택 상태는 안 바뀜)
test:
	for d in 00-iam 10-hub 20-spoke; do (cd stacks/$$d && $(TF) init -backend=false -input=false >/dev/null && TF_WORKSPACE=default $(TF) test) || exit 1; done

fmt:
	$(TF) fmt -recursive
