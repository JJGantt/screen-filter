BIN := $(HOME)/.local/bin
PLIST := $(HOME)/Library/LaunchAgents/com.jaredgantt.screen-filter.plist
DOMAIN := gui/$(shell id -u)
# The daemon runs from an app bundle so Location Services can grant it permission.
APP := ScreenFilter.app
EXE := $(APP)/Contents/MacOS/screenfilter

all: $(EXE) ddc

$(EXE): screenfilter.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	swiftc -O screenfilter.swift -o $(EXE)
	codesign --force --sign - $(APP)

ddc: ddc.swift
	swiftc -O $< -o $@

install: all
	ln -sf $(CURDIR)/$(EXE) $(BIN)/screenfilter
	ln -sf $(CURDIR)/ddc $(BIN)/ddc
	sed "s|@BIN@|$(CURDIR)/$(EXE)|; s|@HOME@|$(HOME)|g" launchd/com.jaredgantt.screen-filter.plist > $(PLIST)
	# Restart in place when loaded: bootout returns before the job is gone, so a following bootstrap fails.
	launchctl bootstrap $(DOMAIN) $(PLIST) 2>/dev/null || launchctl kickstart -k $(DOMAIN)/com.jaredgantt.screen-filter

.PHONY: all install
