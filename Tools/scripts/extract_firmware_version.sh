#!/usr/bin/env bash

# Parse THISFIRMWARE from a vehicle version.h into the version, tag and tag type
# that decide the Google Drive upload folder:
#   "AB ArduPlane V4.6.3.1 rc13 - TRT Mod"  -> version=4.6.3.1 tag=rc13 tag_type=rc
#   "Airbound ArduPlane V6.5.7.9 - hf1"     -> version=6.5.7.9 tag=hf1  tag_type=hf
#   "AB ArduPlane V4.6.3.1 dev - BranchConsolidation v1"
#                                           -> version=4.6.3.1 tag=dev  tag_type=dev
#
# Results are appended to $GITHUB_OUTPUT when set, otherwise printed to stdout.
#
# usage: extract_firmware_version.sh [path/to/version.h]

set -euo pipefail

VERSION_H="${1:-ArduPlane/version.h}"
OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

RAW=$(grep '#define THISFIRMWARE' "${VERSION_H}" | sed 's/#define THISFIRMWARE "\(.*\)"/\1/')
echo "raw=${RAW}"

# version number, e.g. 4.5.7.3
if ! VERSION=$(echo "${RAW}" | grep -oP 'V\K[0-9]+(\.[0-9]+)+'); then
    echo "ERROR: no version number found in THISFIRMWARE \"${RAW}\"" >&2
    exit 1
fi
echo "version=${VERSION}" >> "${OUTPUT}"

# tag: rc1, rc6, hf1, hf2, dev, dev2, etc.
# A tag starts the string or follows a space, "_", "+" or "-"; \K drops that delimiter from the match
# rc and hf require a number, dev does not
# The trailing guard on dev keeps it out of "development", "devel" and "device", and rejects "dev2Feature"
TAG=$(echo "${RAW}" | grep -oiP '(?:^|[\s_+\-])\K((?:rc|hf)\d+|dev\d*(?![A-Za-z0-9]))' | head -1 | tr '[:upper:]' '[:lower:]' || true)
TAG_PREFIX=${TAG//[0-9]/}
if [ -n "${TAG}" ]; then
    echo "tag=${TAG}" >> "${OUTPUT}"
    echo "tag_type=${TAG_PREFIX}" >> "${OUTPUT}"
else
    echo "tag=" >> "${OUTPUT}"
    echo "tag_type=release" >> "${OUTPUT}"
fi

echo "Parsed version=${VERSION} tag=${TAG:-none} type=${TAG_PREFIX:-release}"
