#!/bin/bash
# Prints the app version (single source of truth: Sources/MergeCore/Version.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/MergeCore/Version.swift
