.PHONY: install test clean

BUNDLE_ID := com.mdql.app.preview
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

install:
	@echo "Building mdql (Release)..."
	@xcodebuild -project mdql.xcodeproj -scheme mdql -configuration Release \
		-destination 'platform=macOS' build 2>&1 | tail -3
	@echo ""
	@BUILT="$$(xcodebuild -project mdql.xcodeproj -scheme mdql -configuration Release \
		-showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $$NF}')" && \
		scripts/install.sh "$$BUILT"
	@echo ""
	@# Verify pluginkit registration
	@FINAL="$$(pluginkit -m -v -A -i $(BUNDLE_ID) 2>/dev/null)" && \
		COUNT="$$(echo "$$FINAL" | grep -c '$(BUNDLE_ID)' || true)" && \
		if [ "$$COUNT" -gt 1 ]; then \
			echo "ERROR: $$COUNT pluginkit registrations found (expected 1):"; \
			echo "$$FINAL" | grep '$(BUNDLE_ID)'; \
			exit 1; \
		elif echo "$$FINAL" | grep -Eq '(^|[[:space:]])/Applications/mdql\.app([[:space:]/]|$$)'; then \
			echo "OK: Extension registered from /Applications"; \
		elif echo "$$FINAL" | grep -q '$(BUNDLE_ID)'; then \
			echo "WARN: Registered but not from /Applications:"; \
			echo "$$FINAL" | grep '$(BUNDLE_ID)'; \
		else \
			echo "ERROR: Extension not registered!"; \
			exit 1; \
		fi
	@# Verify no stale lsregister entries
	@STALE="$$($(LSREGISTER) -dump 2>/dev/null | grep 'path:' | grep 'mdql.app' | grep -v '.appex' | grep -Ev 'path:[[:space:]]*/Applications/mdql\.app ' | grep -v 'Application Scripts' | grep -v 'WebKit' || true)" && \
		if [ -n "$$STALE" ]; then \
			echo "WARN: Stale lsregister entries found:"; \
			echo "$$STALE" | sed 's/^/  /'; \
		else \
			echo "OK: No duplicate registrations"; \
		fi
	@echo "Done. Test with: qlmanage -p README.md"

test:
	xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' test

clean:
	xcodebuild -project mdql.xcodeproj -scheme mdql -configuration Release clean
