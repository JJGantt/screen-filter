BIN := $(HOME)/.local/bin
PLIST := $(HOME)/Library/LaunchAgents/com.jaredgantt.screen-filter.plist
DOMAIN := gui/$(shell id -u)

all: screenfilter nightshift ddc

%: %.swift
	swiftc -O $< -o $@

install: all
	ln -sf $(CURDIR)/screenfilter $(BIN)/screenfilter
	ln -sf $(CURDIR)/nightshift $(BIN)/nightshift
	ln -sf $(CURDIR)/ddc $(BIN)/ddc
	sed "s|@BIN@|$(CURDIR)/screenfilter|; s|@HOME@|$(HOME)|g" launchd/com.jaredgantt.screen-filter.plist > $(PLIST)
	-launchctl bootout $(DOMAIN)/com.jaredgantt.screen-filter
	launchctl bootstrap $(DOMAIN) $(PLIST)

.PHONY: all install
