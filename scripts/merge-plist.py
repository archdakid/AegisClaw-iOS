import sys
import plistlib

def merge_plist(source_path, target_path):
    print(f"Reading source: {source_path}")
    with open(source_path, 'rb') as f:
        src = plistlib.load(f)
    print(f"Source has {len(src)} keys: {list(src.keys())}")

    print(f"Reading target: {target_path}")
    with open(target_path, 'rb') as f:
        target = plistlib.load(f)
    print(f"Target originally has {len(target)} keys")

    for k, v in src.items():
        if k == 'CFBundleExecutable' and k in target:
            continue
        target[k] = v

    print(f"Target now has {len(target)} keys: {list(target.keys())}")
    with open(target_path, 'wb') as f:
        plistlib.dump(target, f, fmt=plistlib.FMT_XML)
    print("Successfully wrote merged plist in XML format.")

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: merge-plist.py <source.plist> <target.plist>")
        sys.exit(1)
    merge_plist(sys.argv[1], sys.argv[2])
