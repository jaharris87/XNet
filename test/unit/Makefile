SHELL = /bin/bash

ROOT_DIR := $(abspath ../..)
XNET_DIR := $(ROOT_DIR)/source

include $(XNET_DIR)/Makefile.opt
include $(XNET_DIR)/Makefile.internal

BUILD_DIR := build/$(shell echo $(CMODE) | tr A-Z a-z)
TEST_EXE := $(BUILD_DIR)/xnet_contract_tests
MODULE_FLAGS := -J$(BUILD_DIR) -I$(BUILD_DIR) -I$(XNET_DIR)
PREPROCESS_BUILD_DIR := $(BUILD_DIR)/preprocess
PREPROCESS_MODULE_FLAGS := -J$(PREPROCESS_BUILD_DIR) -I$(PREPROCESS_BUILD_DIR) -I$(XNET_DIR)
PREPROCESS_DIRECT_EXE := $(PREPROCESS_BUILD_DIR)/preprocess_direct
PREPROCESS_NET_SETUP_EXE := $(PREPROCESS_BUILD_DIR)/net_setup
PREPROCESS_VERIFY_EXE := $(PREPROCESS_BUILD_DIR)/verify_preprocess
PREPROCESS_WORK_DIR := $(abspath $(BUILD_DIR)/preprocess-work)
PREPROCESS_FIXTURE_DIR := $(abspath fixtures/preprocess)

OBJECTS := \
  $(BUILD_DIR)/testdrive.o \
  $(BUILD_DIR)/xnet_types.o \
  $(BUILD_DIR)/xnet_constants.o \
  $(BUILD_DIR)/xnet_test_stubs.o \
  $(BUILD_DIR)/xnet_util.o \
  $(BUILD_DIR)/xnet_conditions.o \
  $(BUILD_DIR)/xnet_abundances.o \
  $(BUILD_DIR)/xnet_nnu.o \
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

test: $(TEST_EXE) $(PREPROCESS_DIRECT_EXE) $(PREPROCESS_NET_SETUP_EXE) $(PREPROCESS_VERIFY_EXE)
	@$(TEST_EXE)
	@bash run_preprocess_contracts.sh $(PREPROCESS_FIXTURE_DIR) $(PREPROCESS_WORK_DIR) \
	  $(abspath $(PREPROCESS_DIRECT_EXE)) $(abspath $(PREPROCESS_NET_SETUP_EXE)) \
	  $(abspath $(PREPROCESS_VERIFY_EXE))

$(TEST_EXE): $(OBJECTS)
	$(LDR) -o $@ $(OBJECTS) $(LDFLAGS)

$(BUILD_DIR):
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

clean:
	rm -rf build
