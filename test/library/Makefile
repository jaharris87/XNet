# Compile external callers with the configuration exported by the production build.
# First run make -C ../.. BUILD_NAME=library-test libxnet net_setup xnet.
XNET_CONFIG ?= ../../build/library-test/xnet-config.mk
include $(XNET_CONFIG)

BUILD_DIR ?= build
PROGRAMS := $(BUILD_DIR)/api_consumer $(BUILD_DIR)/legacy_reference $(BUILD_DIR)/failure_consumer
PROGRAMS += $(BUILD_DIR)/output_consumer $(BUILD_DIR)/preprocess_consumer $(BUILD_DIR)/quickstart
XNET_CPP ?= cpp
# This opt-in application caller defaults to GNU OpenMP flags.
HOST_OPENMP_FLAGS ?= -fopenmp
# Optional caller-only host threading for the hardware GPU consumer.
GPU_HOST_OPENMP_FLAGS ?=
ifeq ($(findstring -DXNET_GPU,$(XNET_CPPFLAGS)),)
PROGRAMS += $(BUILD_DIR)/cleanup/cleanup_consumer
CLEANUP_TEST := --cleanup $(BUILD_DIR)/cleanup/cleanup_consumer
endif

.PHONY: all test quickstart-test host-openmp-test host-batch-openmp-test gpu_consumer
all: $(PROGRAMS)
gpu_consumer: $(BUILD_DIR)/gpu_consumer

$(BUILD_DIR):
	mkdir -p '$@'

# Compile the guide's named program, rather than maintaining a second example.
$(BUILD_DIR)/quickstart.f90: ../../docs/development/embedding.md extract_quickstart.py | $(BUILD_DIR)
	python3 -B extract_quickstart.py '$<' '$@'

$(BUILD_DIR)/quickstart.o: $(BUILD_DIR)/quickstart.f90 $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -c '$<' -o '$@'

$(BUILD_DIR)/quickstart: $(BUILD_DIR)/quickstart.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

quickstart-test: $(BUILD_DIR)/quickstart
	python3 -B -m unittest -v test_quickstart
	python3 -B run_quickstart.py --executable $(BUILD_DIR)/quickstart --work-dir $(BUILD_DIR)/quickstart-runs

$(BUILD_DIR)/consumer_fixture.o: consumer_fixture.F90 $(XNET_CONFIG) | $(BUILD_DIR)
	cd '$(BUILD_DIR)' && $(XNET_FC) $(XNET_FFLAGS) -c '$(abspath $<)' -o '$(notdir $@)'

$(BUILD_DIR)/api_consumer.o: api_consumer.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/host_openmp_consumer.o: host_openmp_consumer.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(HOST_OPENMP_FLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/host_openmp_consumer: $(BUILD_DIR)/host_openmp_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) $(HOST_OPENMP_FLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/host_batch_openmp_consumer.o: host_batch_openmp_consumer.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(HOST_OPENMP_FLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/host_batch_openmp_consumer: $(BUILD_DIR)/host_batch_openmp_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) $(HOST_OPENMP_FLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/output_consumer.o: output_consumer.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/output_consumer: $(BUILD_DIR)/output_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/preprocess_consumer.o: preprocess_consumer.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/preprocess_consumer: $(BUILD_DIR)/preprocess_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/legacy_reference.o: legacy_reference.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/failure_consumer.o: failure_consumer.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/gpu_consumer.f90: gpu_consumer.F90 ../../source/xnet_macros.fh $(XNET_CONFIG) | $(BUILD_DIR)
	@case '$(XNET_CPPFLAGS)' in *-DXNET_GPU*) ;; *) echo 'gpu_consumer requires a GPU-enabled libxnet' >&2; exit 2 ;; esac
	$(XNET_CPP) -P -C -nostdinc $(XNET_CPPFLAGS) '$<' > '$@.tmp' && mv '$@.tmp' '$@'

$(BUILD_DIR)/gpu_consumer.o: $(BUILD_DIR)/gpu_consumer.f90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(GPU_HOST_OPENMP_FLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/api_consumer: $(BUILD_DIR)/api_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/legacy_reference: $(BUILD_DIR)/legacy_reference.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/failure_consumer: $(BUILD_DIR)/failure_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/gpu_consumer: $(BUILD_DIR)/gpu_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) $(GPU_HOST_OPENMP_FLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

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

# Exercise production resource cleanup with host-only CUDA/HIP vendor models.
# The replacement interfaces and module outputs never enter normal callers.
ifeq ($(findstring -DXNET_GPU,$(XNET_CPPFLAGS)),)
test host-openmp-test: gpu-finalize-test
GPU_FINALIZE_CUDA := $(BUILD_DIR)/gpu-finalize-cuda/consumer
GPU_FINALIZE_HIP := $(BUILD_DIR)/gpu-finalize-hip/consumer
GPU_FINALIZE_VENDOR := $(BUILD_DIR)/gpu-finalize-vendor.o

.PHONY: gpu-finalize-test
gpu-finalize-test: $(GPU_FINALIZE_CUDA) $(GPU_FINALIZE_HIP)
	@set -e; for executable in $(GPU_FINALIZE_CUDA) $(GPU_FINALIZE_HIP); do \
	  for scenario in stream blas solver both borrowed mixed-blas mixed-solver \
	    init-create-stream init-create-blas init-create-solver init-associate-blas init-associate-solver \
	    init-blas-retry init-solver-retry init-stream-retry init-borrowed init-persistent init-malformed; do \
	    "$$executable" "$$scenario"; \
	  done; \
	done

$(BUILD_DIR)/gpu-finalize-cuda $(BUILD_DIR)/gpu-finalize-hip:
	mkdir -p '$@'

$(GPU_FINALIZE_VENDOR): gpu_finalize_vendor.c | $(BUILD_DIR)
	$(CC) -std=c99 -Wall -Wextra -c '$<' -o '$@'

$(BUILD_DIR)/gpu-finalize-cuda/%.f90: ../../source/%.F90 ../../source/xnet_macros.fh $(XNET_CONFIG) \
    | $(BUILD_DIR)/gpu-finalize-cuda
	$(XNET_CPP) -P -C -nostdinc $(XNET_CPPFLAGS) -DXNET_GPU -DXNET_CUDA '$<' > '$@.tmp' && mv '$@.tmp' '$@'

$(BUILD_DIR)/gpu-finalize-hip/%.f90: ../../source/%.F90 ../../source/xnet_macros.fh $(XNET_CONFIG) \
    | $(BUILD_DIR)/gpu-finalize-hip
	$(XNET_CPP) -P -C -nostdinc $(XNET_CPPFLAGS) -DXNET_GPU -DXNET_HIP '$<' > '$@.tmp' && mv '$@.tmp' '$@'

$(BUILD_DIR)/gpu-finalize-cuda/gpu_finalize_consumer.f90: gpu_finalize_consumer.F90 $(XNET_CONFIG) \
    | $(BUILD_DIR)/gpu-finalize-cuda
	$(XNET_CPP) -P -C -nostdinc $(XNET_CPPFLAGS) -DXNET_GPU -DXNET_CUDA '$<' > '$@.tmp' && mv '$@.tmp' '$@'

$(BUILD_DIR)/gpu-finalize-hip/gpu_finalize_consumer.f90: gpu_finalize_consumer.F90 $(XNET_CONFIG) \
    | $(BUILD_DIR)/gpu-finalize-hip
	$(XNET_CPP) -P -C -nostdinc $(XNET_CPPFLAGS) -DXNET_GPU -DXNET_HIP '$<' > '$@.tmp' && mv '$@.tmp' '$@'

$(BUILD_DIR)/gpu-finalize-cuda/%.o: $(BUILD_DIR)/gpu-finalize-cuda/%.f90 $(XNET_CONFIG)
	cd '$(BUILD_DIR)/gpu-finalize-cuda' && $(XNET_FC) $(XNET_FFLAGS) -I. $(XNET_MODFLAGS) \
	  -c '$(notdir $<)' -o '$(notdir $@)'

$(BUILD_DIR)/gpu-finalize-hip/%.o: $(BUILD_DIR)/gpu-finalize-hip/%.f90 $(XNET_CONFIG)
	cd '$(BUILD_DIR)/gpu-finalize-hip' && $(XNET_FC) $(XNET_FFLAGS) -I. $(XNET_MODFLAGS) \
	  -c '$(notdir $<)' -o '$(notdir $@)'

$(BUILD_DIR)/gpu-finalize-hip/gpu_finalize_hipfort.o: gpu_finalize_hipfort.F90 $(XNET_CONFIG) \
    | $(BUILD_DIR)/gpu-finalize-hip
	cd '$(BUILD_DIR)/gpu-finalize-hip' && $(XNET_FC) $(XNET_FFLAGS) \
	  -c '$(abspath $<)' -o '$(notdir $@)'

$(BUILD_DIR)/gpu-finalize-cuda/xnet_gpu.o: $(BUILD_DIR)/gpu-finalize-cuda/xnet_gpu.f90 \
    $(BUILD_DIR)/gpu-finalize-cuda/cudaf.o \
    $(BUILD_DIR)/gpu-finalize-cuda/cublasf.o $(BUILD_DIR)/gpu-finalize-cuda/cusolverf.o $(XNET_ARCHIVE)
	cd '$(BUILD_DIR)/gpu-finalize-cuda' && $(XNET_FC) $(XNET_FFLAGS) -I. $(XNET_MODFLAGS) \
	  -c '$(notdir $<)' -o '$(notdir $@)'

$(BUILD_DIR)/gpu-finalize-hip/hipf.o $(BUILD_DIR)/gpu-finalize-hip/hipblasf.o \
    $(BUILD_DIR)/gpu-finalize-hip/rocblasf.o $(BUILD_DIR)/gpu-finalize-hip/rocsolverf.o: \
    $(BUILD_DIR)/gpu-finalize-hip/gpu_finalize_hipfort.o

$(BUILD_DIR)/gpu-finalize-hip/xnet_gpu.o: $(BUILD_DIR)/gpu-finalize-hip/xnet_gpu.f90 \
    $(BUILD_DIR)/gpu-finalize-hip/hipf.o \
    $(BUILD_DIR)/gpu-finalize-hip/hipblasf.o $(BUILD_DIR)/gpu-finalize-hip/rocblasf.o \
    $(BUILD_DIR)/gpu-finalize-hip/rocsolverf.o $(XNET_ARCHIVE)
	cd '$(BUILD_DIR)/gpu-finalize-hip' && $(XNET_FC) $(XNET_FFLAGS) -I. $(XNET_MODFLAGS) \
	  -c '$(notdir $<)' -o '$(notdir $@)'

$(BUILD_DIR)/gpu-finalize-cuda/gpu_finalize_consumer.o: $(BUILD_DIR)/gpu-finalize-cuda/xnet_gpu.o
$(BUILD_DIR)/gpu-finalize-hip/gpu_finalize_consumer.o: $(BUILD_DIR)/gpu-finalize-hip/xnet_gpu.o

$(GPU_FINALIZE_CUDA): $(BUILD_DIR)/gpu-finalize-cuda/gpu_finalize_consumer.o \
    $(BUILD_DIR)/gpu-finalize-cuda/xnet_gpu.o $(BUILD_DIR)/gpu-finalize-cuda/cudaf.o \
    $(BUILD_DIR)/gpu-finalize-cuda/cublasf.o $(BUILD_DIR)/gpu-finalize-cuda/cusolverf.o \
    $(GPU_FINALIZE_VENDOR) $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(GPU_FINALIZE_HIP): $(BUILD_DIR)/gpu-finalize-hip/gpu_finalize_consumer.o \
    $(BUILD_DIR)/gpu-finalize-hip/xnet_gpu.o $(BUILD_DIR)/gpu-finalize-hip/hipf.o \
    $(BUILD_DIR)/gpu-finalize-hip/hipblasf.o $(BUILD_DIR)/gpu-finalize-hip/rocblasf.o \
    $(BUILD_DIR)/gpu-finalize-hip/rocsolverf.o $(BUILD_DIR)/gpu-finalize-hip/gpu_finalize_hipfort.o \
    $(GPU_FINALIZE_VENDOR) $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

endif

host-openmp-test: $(BUILD_DIR)/host_openmp_consumer

test host-openmp-test: all quickstart-test
	python3 run_library_tests.py --api $(BUILD_DIR)/api_consumer --reference $(BUILD_DIR)/legacy_reference \
	  --failure $(BUILD_DIR)/failure_consumer --xnet $(dir $(XNET_ARCHIVE))../bin/xnet \
	  --net-setup $(dir $(XNET_ARCHIVE))../bin/net_setup --work-dir $(BUILD_DIR)/runs $(CLEANUP_TEST) \
	  $(if $(filter host-openmp-test,$@),--host-openmp $(BUILD_DIR)/host_openmp_consumer)
	python3 run_output_tests.py --consumer $(BUILD_DIR)/output_consumer --preprocess $(BUILD_DIR)/preprocess_consumer \
	  --net-setup $(dir $(XNET_ARCHIVE))../bin/net_setup --work-dir $(BUILD_DIR)/output-runs

# The application owns the parallel batch loop; this target needs a CPU OPENMP_MODE=ON archive.
host-batch-openmp-test: $(BUILD_DIR)/host_batch_openmp_consumer $(BUILD_DIR)/worker_storage_consumer
	python3 run_host_batch_openmp_tests.py --consumer $(BUILD_DIR)/host_batch_openmp_consumer \
	  --library-config $(XNET_CONFIG) --net-setup $(dir $(XNET_ARCHIVE))../bin/net_setup \
	  --work-dir $(BUILD_DIR)/host-batch-runs --histories \
	  --storage-consumer $(BUILD_DIR)/worker_storage_consumer

# Inspect local shapes, worker addresses, dense strides and idle-worker cleanup.
$(BUILD_DIR)/worker_storage_consumer.o: worker_storage_consumer.F90 $(BUILD_DIR)/consumer_fixture.o $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(HOST_OPENMP_FLAGS) $(XNET_MODFLAGS) -I$(BUILD_DIR) -c '$<' -o '$@'

$(BUILD_DIR)/worker_storage_consumer: $(BUILD_DIR)/worker_storage_consumer.o $(BUILD_DIR)/consumer_fixture.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) $(HOST_OPENMP_FLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

# Test-only EOS observation and whole-evolution serialization control. Keep the
# production archive and its module directory unchanged; link replacements first.
.PHONY: host-batch-openmp-overlap-test
ifeq ($(filter -DXNET_GPU,$(XNET_CPPFLAGS)),)
ifneq ($(filter -DXNET_OMP,$(XNET_CPPFLAGS)),)
$(BUILD_DIR)/overlap $(BUILD_DIR)/overlap/serialized:
	mkdir -p '$@'

$(BUILD_DIR)/overlap/host_overlap_eos.o: host_overlap_eos.F90 $(XNET_CONFIG) | $(BUILD_DIR)/overlap
	cd '$(BUILD_DIR)/overlap' && $(XNET_FC) $(XNET_FFLAGS) $(HOST_OPENMP_FLAGS) $(XNET_MODFLAGS) -c '$(abspath $<)' -o '$(notdir $@)'

$(BUILD_DIR)/overlap/consumer: $(BUILD_DIR)/host_batch_openmp_consumer.o $(BUILD_DIR)/consumer_fixture.o \
    $(BUILD_DIR)/overlap/host_overlap_eos.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) $(HOST_OPENMP_FLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

$(BUILD_DIR)/overlap/serialized/xnet_api.f90: ../../source/xnet_api.F90 ../../source/xnet_macros.fh \
    run_host_overlap_tests.py $(XNET_CONFIG) | $(BUILD_DIR)/overlap/serialized
	$(XNET_CPP) -P -C -nostdinc $(XNET_CPPFLAGS) '$<' > '$@.original'
	python3 -B run_host_overlap_tests.py serialize-api '$@.original' '$@'

$(BUILD_DIR)/overlap/serialized/xnet_api.o: $(BUILD_DIR)/overlap/serialized/xnet_api.f90 $(dir $(XNET_CONFIG))config.txt
	cd '$(BUILD_DIR)/overlap/serialized' && $(XNET_FC) $(XNET_FFLAGS) $(HOST_OPENMP_FLAGS) \
	  $(shell sed -n 's/^XNET_CONTROLS_FFLAGS=//p' '$(dir $(XNET_CONFIG))config.txt') \
	  $(XNET_MODFLAGS) -c '$(notdir $<)' -o '$(notdir $@)'

$(BUILD_DIR)/overlap/serialized/consumer: $(BUILD_DIR)/host_batch_openmp_consumer.o $(BUILD_DIR)/consumer_fixture.o \
    $(BUILD_DIR)/overlap/serialized/xnet_api.o $(BUILD_DIR)/overlap/host_overlap_eos.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) $(HOST_OPENMP_FLAGS) -o '$@' $(filter %.o,$^) $(XNET_ARCHIVE) $(XNET_LIBS)

host-batch-openmp-overlap-test: $(BUILD_DIR)/host_batch_openmp_consumer \
    $(BUILD_DIR)/overlap/consumer $(BUILD_DIR)/overlap/serialized/consumer
	python3 -B run_host_overlap_tests.py run --consumer $(BUILD_DIR)/host_batch_openmp_consumer \
	  --probe $(BUILD_DIR)/overlap/consumer --serialized $(BUILD_DIR)/overlap/serialized/consumer \
	  --library-config $(XNET_CONFIG) --net-setup $(dir $(XNET_ARCHIVE))../bin/net_setup \
	  --work-dir $(BUILD_DIR)/overlap-runs
else
host-batch-openmp-overlap-test:
	@echo 'overlap test requires a CPU OPENMP_MODE=ON library' >&2; exit 2
endif
else
host-batch-openmp-overlap-test:
	@echo 'overlap test requires a CPU OPENMP_MODE=ON library' >&2; exit 2
endif
