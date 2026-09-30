#!/usr/bin/env bash

# Parse THISFIRMWARE from a vehicle version.h into the version, tag and tag type
# that decide the Google Drive upload folder and the label:
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
# A tag starts the string or follows a space, "_", "+" or "-"
TAG_DELIM='(?:^|[\s_+\-])'
TAG_BODY='(?:(?:rc|hf)\d+|dev\d*(?![A-Za-z0-9]))'
TAG=$(echo "${RAW}" | grep -oiP "${TAG_DELIM}\\K${TAG_BODY}" | head -1 | tr '[:upper:]' '[:lower:]' || true)
TAG_PREFIX=${TAG//[0-9]/}

# label: the text after the tag, minus leading delimiters
LABEL=$(echo "${RAW}" | grep -oiP "${TAG_DELIM}${TAG_BODY}\\K.*" | head -1 | sed -E 's/^[[:space:]_+-]+//; s/[[:space:]]+$//' || true)

if [ -n "${TAG}" ]; then
    echo "tag=${TAG}" >> "${OUTPUT}"
    echo "tag_type=${TAG_PREFIX}" >> "${OUTPUT}"
else
    echo "tag=" >> "${OUTPUT}"
    echo "tag_type=release" >> "${OUTPUT}"
fi
echo "label=${LABEL}" >> "${OUTPUT}"

echo "Parsed version=${VERSION} tag=${TAG:-none} type=${TAG_PREFIX:-release} label=${LABEL:-none}"
