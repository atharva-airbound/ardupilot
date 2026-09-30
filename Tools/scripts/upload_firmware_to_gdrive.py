#!/usr/bin/env python3

"""
Upload CI-built firmware to Google Drive.

RC and dev builds go to the RC root, releases and hotfixes to the release root.
All targets share one folder, with the target in the file name:
  rc       <root>/<version>/rcN - <label>/arduplane - <version>-rcN - <label> - <target>.apj
  dev      <root>/<version>/Feature-branches/<label>/arduplane - <version>-dev - <label> - <target>.apj
  hotfix   <root>/<version>/hfN/arduplane-<version>-hfN-<target>.apj
  release  <root>/<version>/arduplane-<version>-<target>.apj
The SITL build uses the same name without the target, as arduplane<...>.exe.

Expects the layout produced by the build_and_upload workflow's download steps:
  firmware_artifacts/firmware-<board>/arduplane.apj
  sitl_artifacts/arduplane.exe

Configured through environment variables:
  GDRIVE_SA_KEY             service account key JSON
  GDRIVE_RC_FOLDER_ID       Drive folder ID for RC and dev builds
  GDRIVE_RELEASE_FOLDER_ID  Drive folder ID for releases and hotfixes
  FW_VERSION, FW_TAG, FW_TAG_TYPE, FW_LABEL  output of extract_firmware_version.sh

AP_FLAKE8_CLEAN
"""

import json
import os
import re

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

BOARDS = ["AB-MOD", "AB-TRT", "AB-V2"]

# tag types that upload to the RC root rather than the release root
RC_TAG_TYPES = ("rc", "dev")

# characters Windows rejects in file names; the label is free text
UNSAFE_CHARS = re.compile(r'[\\/:*?"<>|]')


def safe_name(name):
    """Replace characters that would stop a downloaded file keeping its name."""
    return UNSAFE_CHARS.sub("_", name)


def quote(value):
    """Quote a value for use in a Drive query string."""
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def plan_upload(version, tag, tag_type, label):
    """Return the folder path under the root, the file name stem, and the separator before the target."""
    if tag_type == "rc":
        folders = [version, f"{tag} - {label}" if label else tag]
    elif tag_type == "dev":
        folders = [version, "Feature-branches", label or tag]
    elif tag:
        folders = [version, tag]
    else:
        folders = [version]

    # rc and dev names carry the label, hotfix and release names do not
    if tag_type in RC_TAG_TYPES:
        stem = f"arduplane - {version}-{tag}" + (f" - {label}" if label else "")
        separator = " - "
    else:
        stem = f"arduplane-{version}" + (f"-{tag}" if tag else "")
        separator = "-"

    return [safe_name(folder) for folder in folders], safe_name(stem), separator


def get_or_create_folder(service, name, parent_id):
    """Find an existing folder by name under parent, or create it."""
    query = (
        f"name={quote(name)} and {quote(parent_id)} in parents "
        f"and mimeType='application/vnd.google-apps.folder' and trashed=false"
    )
    results = service.files().list(
        q=query, fields="files(id)",
        supportsAllDrives=True, includeItemsFromAllDrives=True,
    ).execute()
    files = results.get("files", [])
    if files:
        return files[0]["id"]

    metadata = {
        "name": name,
        "mimeType": "application/vnd.google-apps.folder",
        "parents": [parent_id],
    }
    folder = service.files().create(
        body=metadata, fields="id", supportsAllDrives=True,
    ).execute()
    print(f"Created folder: {name}")
    return folder["id"]


def upload_file(service, file_path, parent_id, dest_name=None):
    """Upload a file, replacing it if it already exists."""
    name = dest_name or os.path.basename(file_path)

    query = (
        f"name={quote(name)} and {quote(parent_id)} in parents "
        f"and mimeType!='application/vnd.google-apps.folder' and trashed=false"
    )
    results = service.files().list(
        q=query, fields="files(id)",
        supportsAllDrives=True, includeItemsFromAllDrives=True,
    ).execute()
    existing = results.get("files", [])

    media = MediaFileUpload(file_path)

    if existing:
        service.files().update(
            fileId=existing[0]["id"],
            media_body=media,
            fields="id,name",
            supportsAllDrives=True,
        ).execute()
        print(f"Updated: {name}")
    else:
        metadata = {"name": name, "parents": [parent_id]}
        service.files().create(
            body=metadata,
            media_body=media,
            fields="id,name",
            supportsAllDrives=True,
        ).execute()
        print(f"Uploaded: {name}")


def upload_firmware(service, root_folder_id, folders, stem, separator):
    """Upload every target's firmware and the SITL build into one folder."""
    parent_folder_id = root_folder_id
    for name in folders:
        parent_folder_id = get_or_create_folder(service, name, parent_folder_id)

    for board in BOARDS:
        apj_path = os.path.join("firmware_artifacts", f"firmware-{board}", "arduplane.apj")
        if os.path.exists(apj_path):
            upload_file(service, apj_path, parent_folder_id, f"{stem}{separator}{board}.apj")
        else:
            print(f"WARNING: {apj_path} not found")

    sitl_exe = os.path.join("sitl_artifacts", "arduplane.exe")
    if os.path.exists(sitl_exe):
        upload_file(service, sitl_exe, parent_folder_id, f"{stem}.exe")
    else:
        print(f"WARNING: {sitl_exe} not found")


def main():
    credentials = service_account.Credentials.from_service_account_info(
        json.loads(os.environ["GDRIVE_SA_KEY"]),
        scopes=["https://www.googleapis.com/auth/drive"],
    )

    service = build("drive", "v3", credentials=credentials)
    rc_root_id = os.environ["GDRIVE_RC_FOLDER_ID"]
    release_root_id = os.environ["GDRIVE_RELEASE_FOLDER_ID"]
    version = os.environ["FW_VERSION"]
    tag = os.environ.get("FW_TAG", "")
    tag_type = os.environ.get("FW_TAG_TYPE", "release")
    label = os.environ.get("FW_LABEL", "")

    folders, stem, separator = plan_upload(version, tag, tag_type, label)

    if tag_type in RC_TAG_TYPES:
        # RC and dev versions go to the RC folder only
        print(f"=== Uploading {tag_type} build to RC folder: {'/'.join(folders)} ===")
        upload_firmware(service, rc_root_id, folders, stem, separator)
    else:
        # Releases and hotfixes go to the release folder
        print(f"=== Uploading {tag_type} build to release folder: {'/'.join(folders)} ===")
        upload_firmware(service, release_root_id, folders, stem, separator)

    print("Done.")


if __name__ == "__main__":
    main()
