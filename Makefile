SWIFT ?= swift
SWIFT_BUILD_FLAGS ?=

APP := Launcher.app
CONTENTS := $(APP)/Contents

.PHONY: app
app:
	$(SWIFT) build -c release $(SWIFT_BUILD_FLAGS)
	bin_dir="$$($(SWIFT) build -c release $(SWIFT_BUILD_FLAGS) --show-bin-path)" && \
		mkdir -p "$(CONTENTS)/MacOS" && \
		cp -p "$$bin_dir/launcher" "$(CONTENTS)/MacOS/launcher"
	cp Info.plist "$(CONTENTS)/Info.plist"
	codesign --force --sign - "$(APP)"
