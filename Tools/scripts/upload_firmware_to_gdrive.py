#!/usr/bin/env python3

"""
Upload CI-built firmware to Google Drive.

RC builds go to the RC root, releases and hotfixes to the release root:
  <root>/<version>/[<tag>/]<board>/arduplane.apj
  <root>/<version>/[<tag>/]arduplane.exe

Expects the layout produced by the build_and_upload workflow's download steps:
  firmware_artifacts/firmware-<board>/arduplane.apj
  sitl_artifacts/arduplane.exe

Configured through environment variables:
  GDRIVE_SA_KEY             service account key JSON
  GDRIVE_RC_FOLDER_ID       Drive folder ID for RC builds
  GDRIVE_RELEASE_FOLDER_ID  Drive folder ID for releases and hotfixes
  FW_VERSION, FW_TAG, FW_TAG_TYPE  output of extract_firmware_version.sh

AP_FLAKE8_CLEAN
"""

import json
import os

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

BOARDS = ["AB-MOD", "AB-TRT", "AB-V2"]


def get_or_create_folder(service, name, parent_id):
    """Find an existing folder by name under parent, or create it."""
    query = (
        f"name='{name}' and '{parent_id}' in parents "
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
        f"name='{name}' and '{parent_id}' in parents "
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


def upload_firmware(service, root_folder_id, version, tag):
    """Upload firmware to a Drive folder with the appropriate hierarchy."""
    version_folder_id = get_or_create_folder(service, version, root_folder_id)

    # If there's a tag (rc1, hf1, etc.), create a subfolder for it
    if tag:
        parent_folder_id = get_or_create_folder(service, tag, version_folder_id)
    else:
        parent_folder_id = version_folder_id

    # Upload board firmware: <board>/arduplane.apj
    for board in BOARDS:
        board_folder_id = get_or_create_folder(service, board, parent_folder_id)
        apj_path = os.path.join("firmware_artifacts", f"firmware-{board}", "arduplane.apj")
        if os.path.exists(apj_path):
            upload_file(service, apj_path, board_folder_id)
        else:
            print(f"WARNING: {apj_path} not found")

    # Upload SITL arduplane.exe
    sitl_exe = os.path.join("sitl_artifacts", "arduplane.exe")
    if os.path.exists(sitl_exe):
        upload_file(service, sitl_exe, parent_folder_id)
    else:
        print(f"WARNING: {sitl_exe} not found")


def main():
    credentials = service_account.Credentials.from_service_account_info(
        json.loads(os.environ["GDRIVE_SA_KEY"]),
        scopes=["https://www.googleapis.com/auth/drive.file"],
    )

    service = build("drive", "v3", credentials=credentials)
    rc_root_id = os.environ["GDRIVE_RC_FOLDER_ID"]
    release_root_id = os.environ["GDRIVE_RELEASE_FOLDER_ID"]
    version = os.environ["FW_VERSION"]
    tag = os.environ.get("FW_TAG", "")
    tag_type = os.environ.get("FW_TAG_TYPE", "release")

    if tag_type == "rc":
        # RC versions go to the RC folder only
        print(f"=== Uploading RC build to RC folder: {version}/{tag} ===")
        upload_firmware(service, rc_root_id, version, tag)
    else:
        # Releases and hotfixes go to the release folder
        print(f"=== Uploading to release folder: {version}/{tag or '(root)'} ===")
        upload_firmware(service, release_root_id, version, tag)

    print("Done.")


if __name__ == "__main__":
    main()
