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
        if isinstance(v, str) and v.startswith('$('):
            continue
        target[k] = v

    if 'CFBundleIdentifier' not in target or target['CFBundleIdentifier'].startswith('$('):
        target['CFBundleIdentifier'] = 'com.quincearch.AegisClaw'

    print(f"Target now has {len(target)} keys: {list(target.keys())}")
    with open(target_path, 'wb') as f:
        plistlib.dump(target, f, fmt=plistlib.FMT_BINARY)
    print("Successfully wrote merged plist in binary format.")

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: merge-plist.py <source.plist> <target.plist>")
        sys.exit(1)
    merge_plist(sys.argv[1], sys.argv[2])
