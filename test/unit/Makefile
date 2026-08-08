SHELL = /bin/bash

ROOT_DIR := $(abspath ../..)
XNET_DIR := $(ROOT_DIR)/source

include $(XNET_DIR)/Makefile.opt
include $(XNET_DIR)/Makefile.internal

BUILD_DIR := build/$(shell echo $(CMODE) | tr A-Z a-z)
TEST_EXE := $(BUILD_DIR)/xnet_contract_tests
MODULE_FLAGS := -J$(BUILD_DIR) -I$(BUILD_DIR) -I$(XNET_DIR)

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

.DEFAULT_GOAL := test

.PHONY: test clean

test: $(TEST_EXE)
	@$(TEST_EXE)

$(TEST_EXE): $(OBJECTS)
	$(LDR) -o $@ $(OBJECTS) $(LDFLAGS)

$(BUILD_DIR):
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

clean:
	rm -rf build
