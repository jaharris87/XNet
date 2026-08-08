SHELL = /bin/bash

ROOT_DIR := $(abspath ../..)
XNET_DIR := $(ROOT_DIR)/source
NETLIB_DIR := $(ROOT_DIR)/tools/LAPACK

include $(XNET_DIR)/Makefile.opt
include $(XNET_DIR)/Makefile.internal

BUILD_DIR := build/$(shell echo $(CMODE) | tr A-Z a-z)
TEST_EXE := $(BUILD_DIR)/xnet_contract_tests
NSE_TEST_SOURCE := $(BUILD_DIR)/xnet_nse.F90
MODULE_FLAGS := -J$(BUILD_DIR) -I$(BUILD_DIR) -I$(XNET_DIR)
LAPACK_OBJECTS := $(patsubst $(NETLIB_DIR)/%.f,$(BUILD_DIR)/lapack/%.o,$(LAPACK_SRC))
PREPROCESS_BUILD_DIR := $(BUILD_DIR)/preprocess
PREPROCESS_MODULE_FLAGS := -J$(PREPROCESS_BUILD_DIR) -I$(PREPROCESS_BUILD_DIR) -I$(XNET_DIR)
PREPROCESS_DIRECT_EXE := $(PREPROCESS_BUILD_DIR)/preprocess_direct
PREPROCESS_NET_SETUP_EXE := $(PREPROCESS_BUILD_DIR)/net_setup
PREPROCESS_VERIFY_EXE := $(PREPROCESS_BUILD_DIR)/verify_preprocess
PREPROCESS_WORK_DIR := $(abspath $(BUILD_DIR)/preprocess-work)
PREPROCESS_FIXTURE_DIR := $(abspath fixtures/preprocess)
SPARSE_BUILD_DIR := $(BUILD_DIR)/sparse
SPARSE_WORK_DIR := $(abspath $(BUILD_DIR)/sparse-work)
DENSE_CONTRACT_EXE := $(SPARSE_BUILD_DIR)/dense/sparse_contract_tests
MA48_CONTRACT_EXE := $(SPARSE_BUILD_DIR)/ma48/sparse_contract_tests
PARDISO_CONTRACT_EXE := $(SPARSE_BUILD_DIR)/pardiso/sparse_contract_tests
PARDISO_MKL_CONTRACT_EXE := $(SPARSE_BUILD_DIR)/pardiso_mkl/sparse_contract_tests
SPARSE_CONTRACT_EXES := $(DENSE_CONTRACT_EXE) $(MA48_CONTRACT_EXE) \
  $(PARDISO_CONTRACT_EXE) $(PARDISO_MKL_CONTRACT_EXE)

OBJECTS := \
  $(BUILD_DIR)/testdrive.o \
  $(BUILD_DIR)/xnet_types.o \
  $(BUILD_DIR)/xnet_constants.o \
  $(BUILD_DIR)/xnet_test_stubs.o \
  $(BUILD_DIR)/xnet_timers.o \
  $(BUILD_DIR)/xnet_util.o \
  $(BUILD_DIR)/xnet_conditions.o \
  $(BUILD_DIR)/xnet_abundances.o \
  $(BUILD_DIR)/xnet_nnu.o \
  $(BUILD_DIR)/xnet_nse.o \
  $(LAPACK_OBJECTS) \
  $(BUILD_DIR)/test_xnet_contracts.o

PREPROCESS_CORE_OBJECTS := \
  $(PREPROCESS_BUILD_DIR)/xnet_types.o \
  $(PREPROCESS_BUILD_DIR)/xnet_constants.o \
  $(PREPROCESS_BUILD_DIR)/xnet_parallel_stubs.o \
  $(PREPROCESS_BUILD_DIR)/xnet_util.o \
  $(PREPROCESS_BUILD_DIR)/xnet_controls.o \
  $(PREPROCESS_BUILD_DIR)/xnet_conditions.o \
  $(PREPROCESS_BUILD_DIR)/xnet_fd.o \
  $(PREPROCESS_BUILD_DIR)/xnet_ffn.o \
  $(PREPROCESS_BUILD_DIR)/xnet_nnu.o \
  $(PREPROCESS_BUILD_DIR)/xnet_data.o \
  $(PREPROCESS_BUILD_DIR)/xnet_preprocess.o

PREPROCESS_VERIFY_OBJECTS := \
  $(PREPROCESS_CORE_OBJECTS) \
  $(PREPROCESS_BUILD_DIR)/xnet_match.o \
  $(PREPROCESS_BUILD_DIR)/xnet_abundances.o \
  $(PREPROCESS_BUILD_DIR)/xnet_timers.o \
  $(PREPROCESS_BUILD_DIR)/xnet_jacobian_PARDISO.o \
  $(PREPROCESS_BUILD_DIR)/pardiso_test_stubs.o \
  $(PREPROCESS_BUILD_DIR)/verify_preprocess.o

.DEFAULT_GOAL := test

.PHONY: test clean

test: $(TEST_EXE) $(PREPROCESS_DIRECT_EXE) $(PREPROCESS_NET_SETUP_EXE) $(PREPROCESS_VERIFY_EXE) \
    $(SPARSE_CONTRACT_EXES)
	@$(TEST_EXE)
	@bash run_preprocess_contracts.sh $(PREPROCESS_FIXTURE_DIR) $(PREPROCESS_WORK_DIR) \
	  $(abspath $(PREPROCESS_DIRECT_EXE)) $(abspath $(PREPROCESS_NET_SETUP_EXE)) \
	  $(abspath $(PREPROCESS_VERIFY_EXE))
	@bash run_sparse_contracts.sh $(SPARSE_WORK_DIR) $(abspath $(DENSE_CONTRACT_EXE)) \
	  $(abspath $(MA48_CONTRACT_EXE)) $(abspath $(PARDISO_CONTRACT_EXE)) \
	  $(abspath $(PARDISO_MKL_CONTRACT_EXE)) $(abspath $(XNET_DIR)/sparse_controls.nml)

$(TEST_EXE): $(OBJECTS)
	$(LDR) -o $@ $(OBJECTS) $(LDFLAGS) $(LAPACK_LIBDIR) $(LAPACK_LIBS)

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/lapack:
	mkdir -p $@

$(PREPROCESS_BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/testdrive.o: vendor/test-drive/testdrive.F90 | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(BUILD_DIR)/xnet_types.o: $(XNET_DIR)/xnet_types.F90 | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(BUILD_DIR)/xnet_constants.o: $(XNET_DIR)/xnet_constants.F90 \
    $(BUILD_DIR)/xnet_types.o | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(BUILD_DIR)/xnet_test_stubs.o: support/xnet_test_stubs.F90 \
    $(BUILD_DIR)/xnet_types.o | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(BUILD_DIR)/xnet_timers.o: $(XNET_DIR)/xnet_timers.F90 \
    $(BUILD_DIR)/xnet_types.o | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(BUILD_DIR)/xnet_util.o: $(XNET_DIR)/xnet_util.F90 \
    $(BUILD_DIR)/xnet_constants.o $(BUILD_DIR)/xnet_test_stubs.o | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(BUILD_DIR)/xnet_conditions.o: $(XNET_DIR)/xnet_conditions.F90 \
    $(BUILD_DIR)/xnet_types.o $(BUILD_DIR)/xnet_test_stubs.o | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(BUILD_DIR)/xnet_abundances.o: $(XNET_DIR)/xnet_abundances.F90 \
    $(BUILD_DIR)/xnet_constants.o $(BUILD_DIR)/xnet_test_stubs.o | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(BUILD_DIR)/xnet_nnu.o: $(XNET_DIR)/xnet_nnu.F90 \
    $(BUILD_DIR)/xnet_conditions.o $(BUILD_DIR)/xnet_util.o \
    $(BUILD_DIR)/xnet_test_stubs.o | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(NSE_TEST_SOURCE): $(XNET_DIR)/xnet_nse.F90 | $(BUILD_DIR)
	cp $< $@

$(BUILD_DIR)/xnet_nse.o: $(NSE_TEST_SOURCE) \
    $(BUILD_DIR)/xnet_constants.o $(BUILD_DIR)/xnet_test_stubs.o \
    $(BUILD_DIR)/xnet_timers.o $(BUILD_DIR)/xnet_util.o | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(BUILD_DIR)/lapack/%.o: $(NETLIB_DIR)/%.f | $(BUILD_DIR)/lapack
	$(FC) $(FFLAGS) $(F77FLAGS) $(LAPACK_INC) -c $< -o $@

$(BUILD_DIR)/test_xnet_contracts.o: test_xnet_contracts.F90 $(OBJECTS:$(BUILD_DIR)/test_xnet_contracts.o=) \
    | $(BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_DIRECT_EXE): $(PREPROCESS_CORE_OBJECTS) $(PREPROCESS_BUILD_DIR)/preprocess_direct.o
	$(LDR) -o $@ $^ $(LDFLAGS)

$(PREPROCESS_NET_SETUP_EXE): $(PREPROCESS_CORE_OBJECTS) $(PREPROCESS_BUILD_DIR)/net_setup.o
	$(LDR) -o $@ $^ $(LDFLAGS)

$(PREPROCESS_VERIFY_EXE): $(PREPROCESS_VERIFY_OBJECTS)
	$(LDR) -o $@ $^ $(LDFLAGS)

$(PREPROCESS_BUILD_DIR)/xnet_types.o: $(XNET_DIR)/xnet_types.F90 | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_constants.o: $(XNET_DIR)/xnet_constants.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_types.o | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_parallel_stubs.o: $(XNET_DIR)/xnet_parallel_stubs.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_types.o | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_util.o: $(XNET_DIR)/xnet_util.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_constants.o $(PREPROCESS_BUILD_DIR)/xnet_parallel_stubs.o \
    | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_controls.o: $(XNET_DIR)/xnet_controls.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_constants.o $(PREPROCESS_BUILD_DIR)/xnet_util.o \
    | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_conditions.o: $(XNET_DIR)/xnet_conditions.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_controls.o $(PREPROCESS_BUILD_DIR)/xnet_util.o \
    | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_fd.o: $(XNET_DIR)/xnet_fd.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_types.o | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_ffn.o: $(XNET_DIR)/xnet_ffn.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_conditions.o $(PREPROCESS_BUILD_DIR)/xnet_fd.o \
    | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_nnu.o: $(XNET_DIR)/xnet_nnu.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_conditions.o $(PREPROCESS_BUILD_DIR)/xnet_util.o \
    | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_data.o: $(XNET_DIR)/xnet_data.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_controls.o $(PREPROCESS_BUILD_DIR)/xnet_ffn.o \
    $(PREPROCESS_BUILD_DIR)/xnet_nnu.o | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_preprocess.o: $(XNET_DIR)/xnet_preprocess.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_data.o $(PREPROCESS_BUILD_DIR)/xnet_util.o \
    | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_match.o: $(XNET_DIR)/xnet_match.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_data.o | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_abundances.o: $(XNET_DIR)/xnet_abundances.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_data.o | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_timers.o: $(XNET_DIR)/xnet_timers.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_types.o | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/xnet_jacobian_PARDISO.o: $(XNET_DIR)/xnet_jacobian_PARDISO.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_abundances.o $(PREPROCESS_BUILD_DIR)/xnet_conditions.o \
    $(PREPROCESS_BUILD_DIR)/xnet_data.o $(PREPROCESS_BUILD_DIR)/xnet_timers.o \
    $(PREPROCESS_BUILD_DIR)/xnet_util.o \
    | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/preprocess_direct.o: support/preprocess_direct.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_preprocess.o | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/net_setup.o: $(XNET_DIR)/net_setup.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_preprocess.o | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/pardiso_test_stubs.o: support/pardiso_test_stubs.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_types.o | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(PREPROCESS_BUILD_DIR)/verify_preprocess.o: support/verify_preprocess.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_jacobian_PARDISO.o $(PREPROCESS_BUILD_DIR)/xnet_match.o \
    | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

define sparse_provider_rules
$(SPARSE_BUILD_DIR)/$(1):
	mkdir -p $$@

$(SPARSE_BUILD_DIR)/$(1)/testdrive.o: vendor/test-drive/testdrive.F90 | $(SPARSE_BUILD_DIR)/$(1)
	$$(FC) $$(FFLAGS) $$(F90FLAGS) -J$(SPARSE_BUILD_DIR)/$(1) -I$(SPARSE_BUILD_DIR)/$(1) \
	  -c $$< -o $$@

$(SPARSE_BUILD_DIR)/$(1)/xnet_types.o: $$(XNET_DIR)/xnet_types.F90 | $(SPARSE_BUILD_DIR)/$(1)
	$$(FC) $$(FFLAGS) $$(F90FLAGS) -J$(SPARSE_BUILD_DIR)/$(1) -I$(SPARSE_BUILD_DIR)/$(1) \
	  -c $$< -o $$@

$(SPARSE_BUILD_DIR)/$(1)/sparse_component_stubs.o: support/sparse_component_stubs.F90 \
    $(SPARSE_BUILD_DIR)/$(1)/xnet_types.o | $(SPARSE_BUILD_DIR)/$(1)
	$$(FC) $$(FFLAGS) $$(F90FLAGS) -J$(SPARSE_BUILD_DIR)/$(1) -I$(SPARSE_BUILD_DIR)/$(1) \
	  -c $$< -o $$@

$(SPARSE_BUILD_DIR)/$(1)/solver_component_stubs.o: $(2) \
    $(SPARSE_BUILD_DIR)/$(1)/xnet_types.o | $(SPARSE_BUILD_DIR)/$(1)
	$$(FC) $$(FFLAGS) $$(F90FLAGS) -J$(SPARSE_BUILD_DIR)/$(1) -I$(SPARSE_BUILD_DIR)/$(1) \
	  -c $$< -o $$@

$(SPARSE_BUILD_DIR)/$(1)/xnet_macros.fh: $$(XNET_DIR)/xnet_macros.fh | $(SPARSE_BUILD_DIR)/$(1)
	cp $$< $$@

$(SPARSE_BUILD_DIR)/$(1)/xnet_jacobian.F90: $(3) | $(SPARSE_BUILD_DIR)/$(1)
	cp $$< $$@

$(SPARSE_BUILD_DIR)/$(1)/xnet_jacobian.o: $(SPARSE_BUILD_DIR)/$(1)/xnet_jacobian.F90 \
    $(SPARSE_BUILD_DIR)/$(1)/xnet_macros.fh \
    $(SPARSE_BUILD_DIR)/$(1)/sparse_component_stubs.o \
    $(SPARSE_BUILD_DIR)/$(1)/solver_component_stubs.o | $(SPARSE_BUILD_DIR)/$(1)
	$$(FC) $$(FFLAGS) $$(F90FLAGS) -J$(SPARSE_BUILD_DIR)/$(1) -I$(SPARSE_BUILD_DIR)/$(1) \
	  -c $$< -o $$@

$(SPARSE_BUILD_DIR)/$(1)/test_sparse_contracts.o: test_sparse_contracts.F90 \
    $(SPARSE_BUILD_DIR)/$(1)/testdrive.o $(SPARSE_BUILD_DIR)/$(1)/xnet_jacobian.o \
    $(SPARSE_BUILD_DIR)/$(1)/solver_component_stubs.o | $(SPARSE_BUILD_DIR)/$(1)
	$$(FC) $$(FFLAGS) $$(F90FLAGS) -D$(4) -J$(SPARSE_BUILD_DIR)/$(1) \
	  -I$(SPARSE_BUILD_DIR)/$(1) -c $$< -o $$@

$(SPARSE_BUILD_DIR)/$(1)/sparse_contract_tests: \
    $(SPARSE_BUILD_DIR)/$(1)/testdrive.o \
    $(SPARSE_BUILD_DIR)/$(1)/xnet_types.o \
    $(SPARSE_BUILD_DIR)/$(1)/sparse_component_stubs.o \
    $(SPARSE_BUILD_DIR)/$(1)/solver_component_stubs.o \
    $(SPARSE_BUILD_DIR)/$(1)/xnet_jacobian.o \
    $(SPARSE_BUILD_DIR)/$(1)/test_sparse_contracts.o
	$$(LDR) -o $$@ $$^ $$(LDFLAGS)
endef

$(eval $(call sparse_provider_rules,dense,support/dense_component_stubs.F90,$(XNET_DIR)/xnet_jacobian_dense.F90,TEST_DENSE))
$(eval $(call sparse_provider_rules,ma48,support/ma48_component_stubs.F90,$(XNET_DIR)/xnet_jacobian_MA48.F90,TEST_MA48))
$(eval $(call sparse_provider_rules,pardiso,support/pardiso_component_stubs.F90,$(XNET_DIR)/xnet_jacobian_PARDISO.F90,TEST_PARDISO))
$(eval $(call sparse_provider_rules,pardiso_mkl,support/pardiso_mkl_component_stubs.F90,$(XNET_DIR)/xnet_jacobian_PARDISO_MKL.F90,TEST_PARDISO_MKL))

clean:
	rm -rf build
