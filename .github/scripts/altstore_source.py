"""Writes an AltStore / SideStore source that always lists the newest DriftMail release.

Usage: altstore_source.py <owner/repo> <version> <build> <ipa path> <output path>
"""
import datetime
import json
import os
import sys

repo, version, build, ipa, out = sys.argv[1:6]
base = f"https://github.com/{repo}"
raw = f"https://raw.githubusercontent.com/{repo}/main"
source = {
    "name": "DriftMail",
    "identifier": f"io.github.{repo.replace('/', '.').lower()}.source",
    "subtitle": "A calm, fast mail app built for iPhone Duo.",
    "website": base,
    "iconURL": f"{raw}/DriftMail/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "tintColor": "3D73FA",
    "apps": [
        {
            "name": "DriftMail",
            "bundleIdentifier": "app.driftmail.DriftMail",
            "developerName": repo.split("/")[0],
            "subtitle": "All your inboxes, notified instantly.",
            "localizedDescription": "Unified inbox for Gmail, iCloud, Yahoo, Fastmail and any IMAP account, "
                                    "with free instant notifications and a layout designed for iPhone Duo.",
            "iconURL": f"{raw}/DriftMail/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
            "tintColor": "3D73FA",
            "category": "productivity",
            "versions": [
                {
                    "version": version,
                    "buildVersion": build,
                    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "size": os.path.getsize(ipa),
                    "downloadURL": f"{base}/releases/download/v{version}/DriftMail.ipa",
                    "minOSVersion": "27.1",
                }
            ],
            "appPermissions": {
                "entitlements": ["aps-environment"],
                "privacy": {"NSPhotoLibraryUsageDescription": "DriftMail attaches the photos you choose to your email."},
            },
        }
    ],
    "news": [],
}
with open(out, "w") as f:
    json.dump(source, f, indent=2)
print(f"Wrote {out} for v{version}")
