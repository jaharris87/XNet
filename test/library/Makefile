# Compile external callers with the configuration exported by the production build.
# First run make -C ../.. BUILD_NAME=library-test libxnet net_setup xnet.
XNET_CONFIG ?= ../../build/library-test/xnet-config.mk
include $(XNET_CONFIG)

BUILD_DIR ?= build
PROGRAMS := $(BUILD_DIR)/api_consumer $(BUILD_DIR)/legacy_reference $(BUILD_DIR)/failure_consumer
XNET_CPP ?= cpp
ifeq ($(findstring -DXNET_GPU,$(XNET_CPPFLAGS)),)
PROGRAMS += $(BUILD_DIR)/cleanup/cleanup_consumer
CLEANUP_TEST := --cleanup $(BUILD_DIR)/cleanup/cleanup_consumer
endif

.PHONY: all test gpu_consumer
all: $(PROGRAMS)
gpu_consumer: $(BUILD_DIR)/gpu_consumer

$(BUILD_DIR):
	mkdir -p '$@'

$(BUILD_DIR)/consumer_fixture.o: consumer_fixture.F90 $(XNET_CONFIG) | $(BUILD_DIR)
	cd '$(BUILD_DIR)' && $(XNET_FC) $(XNET_FFLAGS) -c '$(abspath $<)' -o '$(notdir $@)'

$(BUILD_DIR)/api_consumer.o: api_consumer.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/legacy_reference.o: legacy_reference.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/failure_consumer.o: failure_consumer.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/gpu_consumer.f90: gpu_consumer.F90 ../../source/xnet_macros.fh $(XNET_CONFIG) | $(BUILD_DIR)
	@case '$(XNET_CPPFLAGS)' in *-DXNET_GPU*) ;; *) echo 'gpu_consumer requires a GPU-enabled libxnet' >&2; exit 2 ;; esac
	$(XNET_CPP) -P -C -nostdinc $(XNET_CPPFLAGS) '$<' > '$@.tmp' && mv '$@.tmp' '$@'

$(BUILD_DIR)/gpu_consumer.o: $(BUILD_DIR)/gpu_consumer.f90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/api_consumer: $(BUILD_DIR)/api_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/legacy_reference: $(BUILD_DIR)/legacy_reference.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/failure_consumer: $(BUILD_DIR)/failure_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/gpu_consumer: $(BUILD_DIR)/gpu_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

# The simulated resource calls never enter the normal caller module directory.
$(BUILD_DIR)/cleanup:
	mkdir -p '$@'

$(BUILD_DIR)/cleanup/gpu_cleanup_stub.o: gpu_cleanup_stub.F90 $(XNET_CONFIG) | $(BUILD_DIR)/cleanup
	cd '$(BUILD_DIR)/cleanup' && $(XNET_FC) $(XNET_FFLAGS) -c '$(abspath $<)' -o '$(notdir $@)'

$(BUILD_DIR)/cleanup/xnet_api.f90: ../../source/xnet_api.F90 ../../source/xnet_macros.fh $(XNET_CONFIG) | $(BUILD_DIR)/cleanup
	$(XNET_CPP) -P -C -nostdinc $(XNET_CPPFLAGS) -DXNET_GPU '$<' > '$@.tmp' && mv '$@.tmp' '$@'

$(BUILD_DIR)/cleanup/xnet_api.o: $(BUILD_DIR)/cleanup/xnet_api.f90 $(BUILD_DIR)/cleanup/gpu_cleanup_stub.o
	cd '$(BUILD_DIR)/cleanup' && $(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -c '$(notdir $<)' -o '$(notdir $@)'

$(BUILD_DIR)/cleanup/cleanup_consumer.o: cleanup_consumer.F90 $(BUILD_DIR)/cleanup/xnet_api.o
	cd '$(BUILD_DIR)/cleanup' && $(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -c '$(abspath $<)' -o '$(notdir $@)'

$(BUILD_DIR)/cleanup/cleanup_consumer: $(BUILD_DIR)/cleanup/cleanup_consumer.o \
    $(BUILD_DIR)/cleanup/xnet_api.o $(BUILD_DIR)/cleanup/gpu_cleanup_stub.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

test: all
	python3 run_library_tests.py --api $(BUILD_DIR)/api_consumer --reference $(BUILD_DIR)/legacy_reference \
	  --failure $(BUILD_DIR)/failure_consumer --xnet $(dir $(XNET_ARCHIVE))../bin/xnet \
	  --net-setup $(dir $(XNET_ARCHIVE))../bin/net_setup --work-dir $(BUILD_DIR)/runs $(CLEANUP_TEST)
