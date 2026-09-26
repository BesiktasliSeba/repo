#!/bin/bash
# update-repo.sh -- rebuild the Sileo/APT index of this folder.
#
#   ./update-repo.sh [path/to/package.deb ...]
#
# 1. Checks every .deb given on the command line with the source tree's tools/verify-release.sh (the release gate) and copies it into
#    debs/ (by explicit file name; no globs are expanded by this script itself, and older versions of the same package are kept unless
#    you delete them). Only .debs that passed the gate (recorded in debs/.verified) and have no '+debug' Version are ever indexed.
# 2. Reads the control file of every .deb in debs/ and writes Packages, Packages.bz2, Packages.xz
#    (with Filename, Size, MD5sum, SHA1, SHA256 and, when the package has none, Depiction/SileoDepiction/Icon
#    pointing at depictions/<package id>/ if that folder exists).
# 3. Writes Release (Origin/Label/Suite/Version/Codename/Architectures/Components/Description/Date + hashes).
#
# Needs only macOS built-ins + python3 (this Mac has no dpkg-scanpackages; if it is installed, the result is
# the same format). Nothing is uploaded: publishing is a separate, manual `git push` (see README.md).
#
#   ./update-repo.sh --set-base-url https://example.github.io/repo/
# rewrites the base URL in repo.conf and in every JSON/HTML file of this folder.
set -euo pipefail
cd "$(dirname "$0")"
source ./repo.conf

if [ "${1:-}" = "--set-base-url" ]; then
    new="${2:?usage: --set-base-url https://.../}"
    case "$new" in */) ;; *) new="$new/";; esac
    old="$BASE_URL"
    python3 - "$old" "$new" <<'EOF'
import sys, pathlib
old, new = sys.argv[1], sys.argv[2]
for p in [pathlib.Path('repo.conf')] + [p for p in pathlib.Path('.').rglob('*') if p.suffix in ('.json', '.html')]:
    s = p.read_text(encoding='utf-8')
    if old in s:
        p.write_text(s.replace(old, new), encoding='utf-8'); print('updated', p)
EOF
    echo "Base URL is now $new -- run ./update-repo.sh again to refresh Packages/Release."
    exit 0
fi

# Every new .deb must pass the release gate (the source tree's tools/verify-release.sh: a FINALPACKAGE build of the tree's current commit, complete,
# no test machinery). A .deb that passed is recorded by its SHA-256 in debs/.verified; only recorded .debs are ever indexed (below), so a debug
# build or a stale .deb copied into debs/ by hand is refused too.
VERIFY="${MSBD_VERIFY:-$HOME/Desktop/MacStatusBarAndDock.nosync/tools/verify-release.sh}"
mkdir -p debs
touch debs/.verified
for deb in "$@"; do
    [ -f "$deb" ] || { echo "not a file: $deb" >&2; exit 1; }
    case "$deb" in *.deb) ;; *) echo "not a .deb: $deb" >&2; exit 1;; esac
    case "$(basename "$deb")" in *+debug*) echo "refusing a debug build: $deb (build with FINALPACKAGE=1)" >&2; exit 1;; esac
    [ -x "$VERIFY" ] || { echo "the release gate is missing: $VERIFY" >&2; exit 1; }
    if ! out=$("$VERIFY" "$deb" 2>&1) || ! grep -q '^RESULT: GO' <<< "$out"; then
        echo "$out" | grep -E 'NO-GO|RESULT' >&2
        echo "refusing $deb: it did not pass $VERIFY (run it for the details)" >&2; exit 1
    fi
    echo "$(grep '^RESULT' <<< "$out")"
    cp -p "$deb" debs/
    sum=$(shasum -a 256 "debs/$(basename "$deb")" | cut -d' ' -f1)
    grep -q "^$sum " debs/.verified || echo "$sum $(basename "$deb")" >> debs/.verified
    echo "added debs/$(basename "$deb")"
done

export BASE_URL ORIGIN LABEL SUITE VERSION CODENAME ARCHITECTURES COMPONENTS DESCRIPTION
python3 - <<'EOF'
import os, io, tarfile, hashlib, bz2, lzma, time, email.utils

def ar_members(path):
    with open(path, 'rb') as f:
        if f.read(8) != b'!<arch>\n':
            raise ValueError('not an ar archive')
        while True:
            h = f.read(60)
            if len(h) < 60: return
            name = h[:16].decode().strip().rstrip('/')
            size = int(h[48:58].decode().strip())
            data = f.read(size)
            if size % 2: f.read(1)
            yield name, data

def control_of(path):
    for name, data in ar_members(path):
        if name.startswith('control.tar'):
            if name.endswith('.zst'):
                raise ValueError('control.tar.zst is not supported; build with gzip/xz control')
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as t:
                for m in t.getmembers():
                    if m.name.lstrip('./') == 'control':
                        return t.extractfile(m).read().decode('utf-8')
    raise ValueError('no control file')

def parse(text):
    fields, key = [], None
    for line in text.splitlines():
        if not line.strip(): continue
        if line[0] in ' \t' and fields:
            fields[-1][1] += '\n' + line
        else:
            k, _, v = line.partition(':'); fields.append([k.strip(), v.strip()])
    return fields

base = os.environ['BASE_URL']
verified = set()
if os.path.exists(os.path.join('debs', '.verified')):
    verified = {l.split()[0] for l in open(os.path.join('debs', '.verified')) if l.strip()}
entries = []
for fn in sorted(os.listdir('debs')):
    if not fn.endswith('.deb'): continue
    p = os.path.join('debs', fn)
    raw = open(p, 'rb').read()
    fields = parse(control_of(p))
    version = dict((k.lower(), v) for k, v in fields).get('version', '')
    if '+debug' in version:
        raise SystemExit(f'refusing to index {fn}: Version {version} is a debug build (remove it from debs/)')
    if hashlib.sha256(raw).hexdigest() not in verified:
        raise SystemExit(f'refusing to index {fn}: it never passed the release gate (add it with ./update-repo.sh <path>, not by copying)')
    keys = {k.lower() for k, _ in fields}
    pkg = dict((k.lower(), v) for k, v in fields)['package']
    dep_dir = os.path.join('depictions', pkg)
    if os.path.isdir(dep_dir):
        if 'depiction' not in keys: fields.append(['Depiction', f'{base}depictions/{pkg}/'])
        if 'sileodepiction' not in keys and os.path.exists(os.path.join(dep_dir, 'depiction.json')):
            fields.append(['SileoDepiction', f'{base}depictions/{pkg}/depiction.json'])
        if 'icon' not in keys and os.path.exists(os.path.join(dep_dir, 'icon.png')):
            fields.append(['Icon', f'{base}depictions/{pkg}/icon.png'])
    fields = [f for f in fields if f[0].lower() not in ('filename', 'size', 'md5sum', 'sha1', 'sha256')]
    fields += [['Filename', f'./debs/{fn}'], ['Size', str(len(raw))], ['MD5sum', hashlib.md5(raw).hexdigest()],
               ['SHA1', hashlib.sha1(raw).hexdigest()], ['SHA256', hashlib.sha256(raw).hexdigest()]]
    entries.append('\n'.join(f'{k}: {v}' for k, v in fields))
    print(f'indexed {fn} ({pkg})')

packages = ('\n\n'.join(entries) + '\n').encode() if entries else b''
open('Packages', 'wb').write(packages)
open('Packages.bz2', 'wb').write(bz2.compress(packages))
open('Packages.xz', 'wb').write(lzma.compress(packages, format=lzma.FORMAT_XZ))

files = ['Packages', 'Packages.bz2', 'Packages.xz']
e = os.environ
rel = [f"Origin: {e['ORIGIN']}", f"Label: {e['LABEL']}", f"Suite: {e['SUITE']}", f"Version: {e['VERSION']}",
       f"Codename: {e['CODENAME']}", f"Architectures: {e['ARCHITECTURES']}", f"Components: {e['COMPONENTS']}",
       f"Description: {e['DESCRIPTION']}", f"Date: {email.utils.formatdate(time.time(), usegmt=True)}"]
for title, algo in (('MD5Sum', 'md5'), ('SHA1', 'sha1'), ('SHA256', 'sha256')):
    rel.append(f'{title}:')
    for f in files:
        d = open(f, 'rb').read()
        rel.append(f' {hashlib.new(algo, d).hexdigest()} {len(d):>10} {f}')
open('Release', 'w').write('\n'.join(rel) + '\n')
print(f'Packages: {len(entries)} package(s); Release written.')
EOF
[ -f .nojekyll ] || touch .nojekyll
echo "Done. Review with: git status / git diff (in the Pages repository), then push only after your go-ahead."
