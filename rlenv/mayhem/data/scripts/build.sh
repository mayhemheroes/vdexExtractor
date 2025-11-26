#!/bin/bash
set -euo pipefail

# RLENV Build Script
# This script rebuilds the application from source located at /rlenv/source/vdexextractor/
#
# Original image: ghcr.io/mayhemheroes/vdexextractor:master
# Git revision: b90d1338f306618d877c0ca73bfdcf2b8c930ffe

# ============================================================================
# Environment Variables
# ============================================================================
export CC=gcc
export DEBUG=false

# ============================================================================
# REQUIRED: Change to Source Directory
# ============================================================================
cd /rlenv/source/vdexextractor

# ============================================================================
# Clean Previous Build
# ============================================================================
# Clean any previous build artifacts
make clean -C src 2>/dev/null || true
rm -f bin/vdexExtractor 2>/dev/null || true
rm -f /vdexExtractor 2>/dev/null || true

# ============================================================================
# Build Commands
# ============================================================================
# Run the project's build script (which invokes make)
./make.sh

# ============================================================================
# Copy Artifacts (use 'cat >' for busybox compatibility)
# ============================================================================
# Copy the built binary to the expected location
cat bin/vdexExtractor > /vdexExtractor

# ============================================================================
# Set Permissions
# ============================================================================
chmod 777 /vdexExtractor 2>/dev/null || true

# ============================================================================
# REQUIRED: Verify Build Succeeded
# ============================================================================
if [ ! -f /vdexExtractor ]; then
    echo "Error: Build artifact not found at /vdexExtractor"
    exit 1
fi

# Verify executable bit
if [ ! -x /vdexExtractor ]; then
    echo "Warning: Build artifact is not executable"
fi

# Verify file size (should be at least 50KB)
SIZE=$(stat -c%s /vdexExtractor 2>/dev/null || stat -f%z /vdexExtractor 2>/dev/null || echo 0)
if [ "$SIZE" -lt 50000 ]; then
    echo "Warning: Build artifact is suspiciously small ($SIZE bytes)"
fi

echo "Build completed successfully: /vdexExtractor ($SIZE bytes)"
