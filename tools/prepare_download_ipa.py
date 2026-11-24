#!/usr/bin/env python3
"""Prepare an UNSIGNED Telegram IPA for Lead's iOS 17+ download widget.

Usage:
  python3 tools/prepare_download_ipa.py Telegram.ipa --widget LeadDownloadIsland.appex \
      --output Telegram-Downloads-unsigned.ipa

This step only bundles an already-built widget and adds declarations. It
cannot create a provisioning profile or entitlements: sign the main app AND
all embedded extensions after this step.
"""
import argparse
import os
import subprocess
import plistlib
import shutil
import tempfile
import zipfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--widget", type=Path, required=True,
                        help="Un-signed LeadDownloadIsland.appex built by Xcode")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.ipa.is_file():
        parser.error("Input IPA does not exist")
    if not args.widget.is_dir():
        parser.error("Widget .appex directory does not exist")
    if args.output.resolve() == args.ipa.resolve():
        parser.error("Output must not overwrite input")
    with tempfile.TemporaryDirectory(prefix="lead-downloads-") as td:
        root = Path(td)
        # unzip preserves UNIX executable bits and symbolic links in iOS frameworks.
        # zipfile.extractall() does NOT reliably preserve them and can break the app.
        subprocess.run(["unzip", "-q", str(args.ipa.resolve()), "-d", str(root)], check=True)
        apps = list((root / "Payload").glob("*.app"))
        if len(apps) != 1:
            raise SystemExit("Expected exactly one app in Payload")
        app = apps[0]
        plist_path = app / "Info.plist"
        with open(plist_path, "rb") as f:
            info = plistlib.load(f)
        parent_bundle = info.get("CFBundleIdentifier")
        if not parent_bundle:
            raise SystemExit("Host IPA has no CFBundleIdentifier")
        modes = list(info.get("UIBackgroundModes", []))
        if "audio" not in modes:
            modes.append("audio")
        info["UIBackgroundModes"] = modes
        info["NSSupportsLiveActivities"] = True
        info["NSSupportsLiveActivitiesFrequentUpdates"] = True
        with open(plist_path, "wb") as f:
            plistlib.dump(info, f)
        plugins = app / "PlugIns"
        plugins.mkdir(exist_ok=True)
        dest = plugins / "LeadDownloadIsland.appex"
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(args.widget, dest)
        widget_plist = dest / "Info.plist"
        with open(widget_plist, "rb") as f:
            wi = plistlib.load(f)
        wi["CFBundleIdentifier"] = parent_bundle + ".LeadDownloadIsland"
        # XcodeGen's extension Info.plist sometimes loses NSExtension.
        # A WidgetKit .appex without this cannot register with iOS.
        wi["NSExtension"] = {
            "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"
        }
        with open(widget_plist, "wb") as f:
            plistlib.dump(wi, f)
        # Some redistributed IPAs ship the host executable with 0644 mode.
        # Restore execute permissions for every bundled app/extension executable;
        # also ensure the inserted dylib and WidgetKit binary are executable.
        for bundle in [app] + list(app.rglob("*.appex")):
            bp = bundle / "Info.plist"
            if not bp.is_file():
                continue
            with open(bp, "rb") as handle:
                bi = plistlib.load(handle)
            executable = bi.get("CFBundleExecutable")
            if executable:
                binary = bundle / executable
                if binary.is_file():
                    binary.chmod(binary.stat().st_mode | 0o111)
        for dylib in app.rglob("*.dylib"):
            if dylib.is_file():
                dylib.chmod(dylib.stat().st_mode | 0o111)
        # Codesigning must run again: strip invalid stale signatures.
        for directory in (app, dest):
            shutil.rmtree(directory / "_CodeSignature", ignore_errors=True)
            (directory / "embedded.mobileprovision").unlink(missing_ok=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        # zip -y stores symbolic links as links, and -r preserves executable modes.
        subprocess.run(["zip", "-qry", str(args.output.resolve()), "Payload"],
                       cwd=str(root), check=True)
        print(f"Unsigned IPA: {args.output}")
        print(f"Host bundle: {parent_bundle}")
        print(f"Widget bundle: {wi['CFBundleIdentifier']}")
        print("Sign main app and widget extension together; UIBackgroundModes=audio is experimental.")


if __name__ == "__main__":
    main()
