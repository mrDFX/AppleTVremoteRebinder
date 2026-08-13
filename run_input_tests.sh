#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
ARCH=$(uname -m)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/AppleTVremoteRebinder-input-tests.XXXXXX")
TEST_BINARY="$TEST_DIR/InputLifecycleTests"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

CLANG_MODULE_CACHE_PATH="$TEST_DIR/ModuleCache" \
swiftc \
    -sdk "$SDK_PATH" \
    -target "${ARCH}-apple-macosx11.0" \
    -parse-as-library \
    "$ROOT_DIR/RemoteLifecycle.swift" \
    "$ROOT_DIR/Tests/InputLifecycleTests.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"
