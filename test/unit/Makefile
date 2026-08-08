SHELL = /bin/bash

ROOT_DIR := $(abspath ../..)
XNET_DIR := $(ROOT_DIR)/source
NETLIB_DIR := $(ROOT_DIR)/tools/LAPACK
BUILD_NET_SOURCE_DIR := $(ROOT_DIR)/test/build_net
HELM_TABLE := $(ROOT_DIR)/tools/starkiller-helmholtz/helm_table.dat

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
BUILD_NET_READER_EXE := $(PREPROCESS_BUILD_DIR)/verify_build_net_readers
PREPROCESS_WORK_DIR := $(abspath $(BUILD_DIR)/preprocess-work)
PREPROCESS_FIXTURE_DIR := $(abspath fixtures/preprocess)
BUILD_NET_BUILD_DIR := $(BUILD_DIR)/build-net
BUILD_NET_MODULE_FLAGS := -J$(BUILD_NET_BUILD_DIR) -I$(BUILD_NET_BUILD_DIR)
BUILD_NET_EXE := $(BUILD_NET_BUILD_DIR)/build_net
BUILD_NET_WORK_DIR := $(abspath $(BUILD_DIR)/build-net-work)
PRODUCTION_XNET_EXE := $(XNET_DIR)/xnet
PRODUCTION_XNET_STAMP := $(BUILD_DIR)/production-xnet.stamp
PRODUCTION_XNET_SOURCES := $(wildcard $(XNET_DIR)/*.F90 $(XNET_DIR)/*.f90) \
  $(XNET_DIR)/Makefile $(XNET_DIR)/Makefile.opt $(XNET_DIR)/Makefile.internal

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

BUILD_NET_OBJECTS := \
  $(BUILD_NET_BUILD_DIR)/net_module.o \
  $(BUILD_NET_BUILD_DIR)/partf_module.o \
  $(BUILD_NET_BUILD_DIR)/ffn_module.o \
  $(BUILD_NET_BUILD_DIR)/nnu_module.o \
  $(BUILD_NET_BUILD_DIR)/file_module.o \
  $(BUILD_NET_BUILD_DIR)/reaclib_reader.o

.DEFAULT_GOAL := test

.PHONY: test clean

test: $(TEST_EXE) $(PREPROCESS_DIRECT_EXE) $(PREPROCESS_NET_SETUP_EXE) $(PREPROCESS_VERIFY_EXE) \
    $(BUILD_NET_READER_EXE) $(BUILD_NET_EXE) $(PRODUCTION_XNET_STAMP)
	@$(TEST_EXE)
	@bash run_preprocess_contracts.sh $(PREPROCESS_FIXTURE_DIR) $(PREPROCESS_WORK_DIR) \
	  $(abspath $(PREPROCESS_DIRECT_EXE)) $(abspath $(PREPROCESS_NET_SETUP_EXE)) \
	  $(abspath $(PREPROCESS_VERIFY_EXE))
	@python3 run_build_net_contracts.py $(BUILD_NET_WORK_DIR) $(abspath $(BUILD_NET_EXE)) \
	  $(abspath $(PREPROCESS_NET_SETUP_EXE)) $(abspath $(BUILD_NET_READER_EXE)) \
	  $(abspath $(PRODUCTION_XNET_EXE)) $(abspath $(HELM_TABLE))

$(TEST_EXE): $(OBJECTS)
	$(LDR) -o $@ $(OBJECTS) $(LDFLAGS) $(LAPACK_LIBDIR) $(LAPACK_LIBS)

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/lapack:
	mkdir -p $@

$(PREPROCESS_BUILD_DIR):
	mkdir -p $@

$(BUILD_NET_BUILD_DIR):
	mkdir -p $@

$(PRODUCTION_XNET_STAMP): $(PRODUCTION_XNET_SOURCES) | $(BUILD_DIR)
	$(MAKE) -C $(XNET_DIR) clean
	$(MAKE) -C $(XNET_DIR) -j CMODE=$(CMODE)
	touch $@

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

$(BUILD_NET_READER_EXE): $(PREPROCESS_VERIFY_OBJECTS:$(PREPROCESS_BUILD_DIR)/verify_preprocess.o=) \
    $(PREPROCESS_BUILD_DIR)/verify_build_net_readers.o
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

$(PREPROCESS_BUILD_DIR)/verify_build_net_readers.o: support/verify_build_net_readers.F90 \
    $(PREPROCESS_BUILD_DIR)/xnet_jacobian_PARDISO.o $(PREPROCESS_BUILD_DIR)/xnet_match.o \
    | $(PREPROCESS_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(PREPROCESS_MODULE_FLAGS) -c $< -o $@

$(BUILD_NET_EXE): $(BUILD_NET_OBJECTS)
	$(LDR) -o $@ $^ $(LDFLAGS)

$(BUILD_NET_BUILD_DIR)/net_module.o: $(BUILD_NET_SOURCE_DIR)/net_module.f90 | $(BUILD_NET_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(BUILD_NET_MODULE_FLAGS) -c $< -o $@

$(BUILD_NET_BUILD_DIR)/partf_module.o: $(BUILD_NET_SOURCE_DIR)/partf_module.f90 \
    $(BUILD_NET_BUILD_DIR)/net_module.o | $(BUILD_NET_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(BUILD_NET_MODULE_FLAGS) -c $< -o $@

$(BUILD_NET_BUILD_DIR)/ffn_module.o: $(BUILD_NET_SOURCE_DIR)/ffn_module.f90 \
    $(BUILD_NET_BUILD_DIR)/net_module.o $(BUILD_NET_BUILD_DIR)/partf_module.o \
    | $(BUILD_NET_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(BUILD_NET_MODULE_FLAGS) -c $< -o $@

$(BUILD_NET_BUILD_DIR)/nnu_module.o: $(BUILD_NET_SOURCE_DIR)/nnu_module.f90 \
    $(BUILD_NET_BUILD_DIR)/net_module.o | $(BUILD_NET_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(BUILD_NET_MODULE_FLAGS) -c $< -o $@

$(BUILD_NET_BUILD_DIR)/file_module.o: $(BUILD_NET_SOURCE_DIR)/file_module.f90 \
    $(BUILD_NET_BUILD_DIR)/net_module.o $(BUILD_NET_BUILD_DIR)/partf_module.o \
    $(BUILD_NET_BUILD_DIR)/ffn_module.o $(BUILD_NET_BUILD_DIR)/nnu_module.o \
    | $(BUILD_NET_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(BUILD_NET_MODULE_FLAGS) -c $< -o $@

$(BUILD_NET_BUILD_DIR)/reaclib_reader.o: $(BUILD_NET_SOURCE_DIR)/reaclib_reader.f90 \
    $(BUILD_NET_BUILD_DIR)/file_module.o | $(BUILD_NET_BUILD_DIR)
	$(FC) $(FFLAGS) $(F90FLAGS) $(BUILD_NET_MODULE_FLAGS) -c $< -o $@

clean:
	rm -rf build
