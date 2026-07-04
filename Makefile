.PHONY: foxtrot.h
foxtrot.h:
	cbindgen ffi -o QuickLookStep/foxtrot.h -l c

.PHONY: libfoxtrot_universal.a
libfoxtrot_universal.a:
	cargo build --release --target aarch64-apple-darwin -p foxtrot_ffi
	cargo build --release --target x86_64-apple-darwin -p foxtrot_ffi
	lipo -create \
    target/x86_64-apple-darwin/release/libfoxtrot_ffi.a \
    target/aarch64-apple-darwin/release/libfoxtrot_ffi.a \
    -output QuickLookStep/libfoxtrot_universal.a

.PHONY: test-foxtrot
test-foxtrot:
	cd foxtrot && cargo run --release -- examples/cube_hole.step

.PHONY: xcodebuild
xcodebuild:
	xcodebuild \
	  -project QuickLookStep/QuickLookStep.xcodeproj \
	  -scheme QuickLookStep \
	  -configuration Release \
	  -destination 'generic/platform=macOS' \
	  -derivedDataPath build \
	  build

.PHONY: quicklook-commit-build
quicklook-commit-build: foxtrot.h libfoxtrot_universal.a
	xcodebuild \
	  -project QuickLookStep/QuickLookStep.xcodeproj \
	  -scheme QuickLookStep \
	  -configuration Debug \
	  -derivedDataPath build \
	  CODE_SIGNING_ALLOWED=NO \
	  CODE_SIGNING_REQUIRED=NO \
	  CODE_SIGN_IDENTITY="" \
	  build

.PHONY: install-quicklook-hooks
install-quicklook-hooks:
	mkdir -p .githooks
	git config --local core.hooksPath .githooks
