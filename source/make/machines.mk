# Host detection and explicit repository-owned machine-family selection.
ifdef LMOD_SYSTEM_NAME
  MACHINE = $(LMOD_SYSTEM_NAME)
else
  MACHINE = $(shell uname -n | sed 's/\..*//; s/\(-[a-zA-Z0-9]*\)\?[0-9]*$$//')
endif

CRAY_PE_HOSTS := frontier titan perlmutter edison cori chester beacon
LEGACY_IBM_HOSTS := summit summitdev mira

ifeq ($(findstring $(MACHINE),$(CRAY_PE_HOSTS)),$(MACHINE))
  include $(XNET_DIR)/make/machines/cray-pe.mk
else
  include $(XNET_DIR)/make/machines/generic.mk
endif
