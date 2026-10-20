import zipfile
import plistlib
import stat
import os
import sys

def clean_ipa(ipa_path, output_path=None):
    if output_path is None:
        output_path = ipa_path
        temp_out = ipa_path + ".tmp.ipa"
    else:
        temp_out = output_path

    print(f"Inspecting {ipa_path}...")
    with zipfile.ZipFile(ipa_path, 'r') as zin:
        names = zin.namelist()
        has_resources_dir = any("Payload/AegisClaw.app/Resources/" in n for n in names)
        print(f"Contains top-level Resources folder: {has_resources_dir}")

        info_plist_entry = None
        for n in names:
            if n.endswith(".app/Info.plist"):
                info_plist_entry = n
                break

        info_plist_bytes = zin.read(info_plist_entry) if info_plist_entry else None
        if info_plist_bytes:
            parsed = plistlib.loads(info_plist_bytes)

            # Locate and merge Config/Info.plist to guarantee modern screen adaptation & permissions
            repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            config_plist = os.path.join(repo_root, "Config", "Info.plist")
            if os.path.exists(config_plist):
                with open(config_plist, "rb") as cf:
                    cfg_parsed = plistlib.load(cf)
                    for k, v in cfg_parsed.items():
                        # Do not override binary executable or bundle ID if already set
                        if k in ["CFBundleExecutable", "CFBundleIdentifier"] and k in parsed:
                            continue
                        if k not in parsed or k in ["UILaunchScreen", "UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace", "UISupportedInterfaceOrientations"]:
                            parsed[k] = v

            # Mandatory UILaunchScreen dictionary with UIColorName so iOS activates native screen resolution (prevents zoom/letterbox)
            if "UILaunchScreen" not in parsed or not isinstance(parsed["UILaunchScreen"], dict) or not parsed["UILaunchScreen"]:
                parsed["UILaunchScreen"] = {"UIColorName": "systemBackgroundColor"}

            if "UISupportedInterfaceOrientations" not in parsed:
                parsed["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]

            xml_plist = plistlib.dumps(parsed, fmt=plistlib.FMT_XML)
        else:
            xml_plist = None

        seen_names = set()
        with zipfile.ZipFile(temp_out, 'w', zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                name = item.filename
                # Skip the exact folder entry 'Payload/AegisClaw.app/Resources/'
                if name == "Payload/AegisClaw.app/Resources/":
                    continue

                if "Payload/AegisClaw.app/Resources/" in name:
                    new_name = name.replace("Payload/AegisClaw.app/Resources/", "Payload/AegisClaw.app/")
                else:
                    new_name = name

                if new_name in seen_names:
                    continue
                seen_names.add(new_name)

                data = zin.read(name)
                if new_name == info_plist_entry and xml_plist is not None:
                    data = xml_plist

                zinfo = zipfile.ZipInfo(new_name)
                zinfo.external_attr = item.external_attr
                zout.writestr(zinfo, data)

    if temp_out != output_path:
        os.replace(temp_out, output_path)
    elif output_path == ipa_path:
        os.replace(temp_out, ipa_path)

    print(f"Successfully cleaned and saved to {output_path}")

if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "AegisClaw-unsigned.ipa"
    out = sys.argv[2] if len(sys.argv) > 2 else target
    clean_ipa(target, out)
