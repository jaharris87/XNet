# Build the benchmark device probe with the exact production configuration.
# GNU Make runs this file with CURDIR set to the captured source checkout.
include make/build.mk

PROBE_SRC := $(BENCHMARK_HARNESS_DIR)/gpu_execution_probe.F90
PROBE_PP := $(PP_DIR)/benchmark/gpu_execution_probe.f90
PROBE_OBJ := $(OBJ_DIR)/benchmark/gpu_execution_probe.o
PROBE_EXE := $(BIN_DIR)/xnet_benchmark_gpu_probe
PROBE_SUPPORT_OBJ := $(filter-out $(call SOBJ,model_input_ascii) $(call SOBJ,net),$(XNET_OBJ))
OPENMP_PROBE_SRC := $(BENCHMARK_HARNESS_DIR)/openmp_execution_probe.F90
OPENMP_PROBE_OBJ := $(OBJ_DIR)/benchmark/openmp_execution_probe.o
OPENMP_PROBE_EXE := $(BIN_DIR)/xnet_benchmark_openmp_probe

.PHONY: xnet_benchmark_gpu_probe
xnet_benchmark_gpu_probe: $(PROBE_EXE)

.PHONY: xnet_benchmark_openmp_probe
xnet_benchmark_openmp_probe: $(OPENMP_PROBE_EXE)

$(dir $(PROBE_PP)) $(dir $(PROBE_OBJ)): | $(CONFIG)
	mkdir -p '$@'

$(PROBE_PP): $(PROBE_SRC) $(PP_STATIC_INPUTS) $(CONFIG) | $(dir $(PROBE_PP))
ifeq ($(CRAY_OMP_PREPROCESS),yes)
	@XNET_CPP_OUTPUT='$@.$$$$.tmp' XNET_CPP='$(XNET_CPP)' \
	  $(ROOT_DIR)/make/crayftn_cpp.sh $(CPP_EFFECTIVE_FLAGS) '$<' && mv '$@.$$$$.tmp' '$@'
else
	@$(XNET_CPP) $(CPP_EFFECTIVE_FLAGS) '$<' > '$@.$$$$.tmp' && mv '$@.$$$$.tmp' '$@'
endif

$(PROBE_OBJ): $(PROBE_PP) $(call SOBJ,xnet_controls) $(call SOBJ,xnet_gpu) \
    $(call SOBJ,xnet_linalg) $(call SOBJ,xnet_types) | $(dir $(PROBE_OBJ)) $(MOD_DIR)
	$(COMPILE_FC) $(COMPILE_FFLAGS) $(COMPILE_F90FLAGS) $(MODULE_FLAGS) \
	  $(LAPACK_INC) $(SOLVER_INC) $(CPP_INCLUDE_FLAGS) $(GPU_MODULE_FLAGS) \
	  -c '$<' -o '$@'

$(PROBE_EXE): $(PROBE_SUPPORT_OBJ) $(PROBE_OBJ) | $(BIN_DIR)
	$(LDR) $(LDFLAGS) -o '$@.$$$$.tmp' $(PROBE_SUPPORT_OBJ) $(PROBE_OBJ) \
	  $(SOLVER_LIBDIR) $(SOLVER_LIBS) $(LAPACK_LIBDIR) $(LAPACK_LIBS) && mv '$@.$$$$.tmp' '$@'

$(OPENMP_PROBE_OBJ): $(OPENMP_PROBE_SRC) $(CONFIG) | $(dir $(PROBE_OBJ)) $(MOD_DIR)
	$(COMPILE_FC) $(COMPILE_FFLAGS) $(COMPILE_F90FLAGS) $(MODULE_FLAGS) -c '$<' -o '$@'

$(OPENMP_PROBE_EXE): $(OPENMP_PROBE_OBJ) | $(BIN_DIR)
	$(LDR) $(LDFLAGS) -o '$@.$$$$.tmp' $(OPENMP_PROBE_OBJ) && mv '$@.$$$$.tmp' '$@'
