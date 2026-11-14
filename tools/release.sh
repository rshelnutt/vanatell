#!/usr/bin/env bash
# VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
#
# Publishes a tagged release of the addon, as CHANGELOG.md's release steps say:
#   1. builds vanatell-vX.Y.Z.zip (Windower) and vanatell-ashita-vX.Y.Z.zip
#      (Ashita) from the tag, exactly as CHANGELOG.md's recipe does;
#   2. writes the update manifest, latest.json: the version and, for each
#      zip, every file's path (inside vanatell/), SHA-256 and size;
#   3. uploads every file to the R2 bucket vanatell-downloads as
#      addon/vX.Y.Z/<windower|ashita>/<path>, reads each one back and checks
#      its SHA-256, and only then uploads addon/latest.json (and checks it);
#   4. creates the GitHub release vX.Y.Z, marked Latest, with this version's
#      CHANGELOG section as its notes and both zips attached;
#   5. bumps the site's download cache key (?vanatell-tag=) in
#      vanatell-site/src/index.ts and deploys the site;
#   6. checks from outside: https://vanatell.com/addon/latest.json is this
#      manifest, every file it names is served with that hash and size, and
#      /download/addon and /download/ashita lead to this release's zips.
# The tag must be pushed first. Commit and push the site's cache key change
# afterwards.
#
#   tools/release.sh vX.Y.Z [--out DIR]
#   tools/release.sh vX.Y.Z --local STATE [--out DIR]
#
# --out DIR     keep the zips and latest.json in DIR (default: a new temp folder)
# --local STATE steps 1 to 3 only, into wrangler's local R2 state in STATE
#               (what `wrangler dev --persist-to STATE` serves), for testing
#
# Needs git, zip, python3, and the vanatell-site checkout with its
# node_modules (VANATELL_SITE_DIR, default ../vanatell-site next to this
# repo). The real release also needs gh logged in and
# VANATELL_CLOUDFLARE_API_TOKEN in the environment (~/.zshenv).
set -euo pipefail

usage() {
  echo "usage: tools/release.sh vX.Y.Z [--local STATE] [--out DIR]" >&2
  exit 2
}

TAG="${1:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
shift
VERSION="${TAG#v}"
LOCAL=""
OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --local) [ "$#" -ge 2 ] || usage; LOCAL="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${VANATELL_SITE_DIR:-$REPO/../vanatell-site}"
BUCKET=vanatell-downloads
SITE_URL=https://vanatell.com

die() {
  echo "release: $*" >&2
  exit 1
}

[ -x "$SITE/node_modules/.bin/wrangler" ] || die "no wrangler in $SITE/node_modules; run pnpm install there, or set VANATELL_SITE_DIR"
SITE="$(cd "$SITE" && pwd)"
command -v python3 >/dev/null || die "python3 not found"
command -v zip >/dev/null || die "zip not found"

cd "$REPO"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "no tag $TAG in $REPO"
# grep reads to the end (no -q): with pipefail, -q quitting early breaks git show's pipe and fails the check.
git show "$TAG:vanatell.lua" | grep -x "_addon.version = '$VERSION'" >/dev/null || die "vanatell.lua at $TAG is not version $VERSION"
git show "$TAG:ashita/vanatell.lua" | grep -x "addon.version = '$VERSION'" >/dev/null || die "ashita/vanatell.lua at $TAG is not version $VERSION"
git show "$TAG:CHANGELOG.md" | grep "^## \[$VERSION\] - " >/dev/null || die "CHANGELOG.md at $TAG has no [$VERSION] section"

if [ -n "$LOCAL" ]; then
  mkdir -p "$LOCAL"
  LOCAL="$(cd "$LOCAL" && pwd)"
  WHERE=(--local --persist-to "$LOCAL")
else
  WHERE=(--remote)
  [ -n "${VANATELL_CLOUDFLARE_API_TOKEN:-}" ] || die "VANATELL_CLOUDFLARE_API_TOKEN is not set (source ~/.zshenv)"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in"
  [ "$(git ls-remote --tags origin "refs/tags/$TAG" | cut -f1)" = "$(git rev-parse "refs/tags/$TAG")" ] \
    || die "push $TAG first: origin does not have it at the same commit"
  if gh release view "$TAG" >/dev/null 2>&1; then die "the GitHub release $TAG already exists"; fi
  grep -Eq '\?vanatell-tag=v[0-9]+\.[0-9]+\.[0-9]+"' "$SITE/src/index.ts" || die "no ?vanatell-tag= cache key in $SITE/src/index.ts"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [ -z "$OUT" ]; then OUT="$(mktemp -d)"; fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WIN_ZIP="$OUT/vanatell-$TAG.zip"
ASHITA_ZIP="$OUT/vanatell-ashita-$TAG.zip"
rm -f "$WIN_ZIP" "$ASHITA_ZIP"

wrangler() {
  (cd "$SITE" && CLOUDFLARE_API_TOKEN="${VANATELL_CLOUDFLARE_API_TOKEN:-}" ./node_modules/.bin/wrangler "$@")
}

# 1. The zips, as CHANGELOG.md's steps 3 and 4 build them.
echo "release: building the zips for $TAG"
git archive --format=zip --prefix=vanatell/ -o "$WIN_ZIP" "$TAG"
B="$WORK/ashita"
mkdir -p "$B/vanatell"
git archive "$TAG" | tar -x -C "$B/vanatell"
mv "$B/vanatell/vanatell.lua" "$B/vanatell/main.lua"
git show "$TAG:ashita/vanatell.lua" > "$B/vanatell/vanatell.lua"
(cd "$B" && zip -qrX - vanatell) > "$ASHITA_ZIP"

# 2. The manifest, from the zips themselves; each file is staged under
# STAGE/<platform>/<path>, and FILES lists platform, path, sha256, content type.
STAGE="$WORK/stage"
FILES="$WORK/files.tsv"
python3 -I - "$VERSION" "$WIN_ZIP" "$ASHITA_ZIP" "$STAGE" "$OUT/latest.json" "$FILES" <<'PY'
import hashlib, json, os, re, sys, zipfile
version, win_zip, ashita_zip, stage, manifest_path, files_path = sys.argv[1:]
PART = re.compile(r'^[A-Za-z0-9_.\-]+$')
RESERVED = {'con', 'prn', 'aux', 'nul'} | {'com%d' % i for i in range(1, 10)} | {'lpt%d' % i for i in range(1, 10)}

def check(path):
    parts = path.split('/')
    ok = 0 < len(parts) <= 3 and len(path) <= 128 and not path.lower().endswith('.vtnew') \
        and parts[0].lower() not in ('data', 'backup') \
        and all(PART.match(p) and p not in ('.', '..') and not p.endswith('.') and p.split('.')[0].lower() not in RESERVED
                for p in parts)
    if not ok:
        sys.exit('release: the zips hold a path the addon would refuse: ' + path)

def kind(path):
    name = path.rsplit('/', 1)[-1].lower()
    for ext, ct in (('.json', 'application/json'), ('.lua', 'text/x-lua; charset=utf-8'),
                    ('.md', 'text/markdown; charset=utf-8'), ('.png', 'image/png')):
        if name.endswith(ext):
            return ct
    return 'text/plain; charset=utf-8'

manifest = {'version': version}
rows = []
for platform, zpath in (('windower', win_zip), ('ashita', ashita_zip)):
    files = []
    with zipfile.ZipFile(zpath) as z:
        for info in sorted(z.infolist(), key=lambda i: i.filename):
            if info.is_dir():
                continue
            if not info.filename.startswith('vanatell/'):
                sys.exit('release: %s holds %s outside vanatell/' % (zpath, info.filename))
            path = info.filename[len('vanatell/'):]
            check(path)
            data = z.read(info)
            target = os.path.join(stage, platform, *path.split('/'))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, 'wb') as f:
                f.write(data)
            sha = hashlib.sha256(data).hexdigest()
            files.append({'path': path, 'sha256': sha, 'size': len(data)})
            rows.append('\t'.join((platform, path, sha, kind(path))))
    if not any(f['path'] == 'vanatell.lua' for f in files):
        sys.exit('release: %s has no vanatell/vanatell.lua' % zpath)
    manifest[platform] = {'files': files}
with open(manifest_path, 'w') as f:
    f.write(json.dumps(manifest, separators=(',', ':')) + '\n')
with open(files_path, 'w') as f:
    f.write('\n'.join(rows) + '\n')
print('release: manifest: %d Windower files, %d Ashita files' % (len(manifest['windower']['files']), len(manifest['ashita']['files'])))
PY

sha256_of() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

# 3. Every file up and read back, then latest.json last.
echo "release: uploading to R2 ($BUCKET${LOCAL:+, local state in $LOCAL})"
while IFS=$'\t' read -r platform path sha ct; do
  key="addon/$TAG/$platform/$path"
  wrangler r2 object put "$BUCKET/$key" --file "$STAGE/$platform/$path" --content-type "$ct" "${WHERE[@]}" >/dev/null
done < "$FILES"
echo "release: reading every file back"
while IFS=$'\t' read -r platform path sha ct; do
  key="addon/$TAG/$platform/$path"
  rm -f "$WORK/back"
  wrangler r2 object get "$BUCKET/$key" --file "$WORK/back" "${WHERE[@]}" >/dev/null
  [ "$(sha256_of "$WORK/back")" = "$sha" ] || die "$key read back with another SHA-256; latest.json not uploaded"
done < "$FILES"
wrangler r2 object put "$BUCKET/addon/latest.json" --file "$OUT/latest.json" --content-type application/json \
  --cache-control "public, max-age=60" "${WHERE[@]}" >/dev/null
rm -f "$WORK/back"
wrangler r2 object get "$BUCKET/addon/latest.json" --file "$WORK/back" "${WHERE[@]}" >/dev/null
cmp -s "$WORK/back" "$OUT/latest.json" || die "addon/latest.json read back different"
echo "release: R2 holds $TAG and addon/latest.json names it"

if [ -n "$LOCAL" ]; then
  echo "release: local only; zips and latest.json in $OUT"
  exit 0
fi

# 4. The GitHub release: this version's CHANGELOG section, both zips, Latest.
NOTES="$WORK/notes.md"
git show "$TAG:CHANGELOG.md" | python3 -I -c '
import re, sys
version = sys.argv[1]
text = sys.stdin.read()
m = re.search(r"^## \[" + re.escape(version) + r"\] - [^\n]*\n(.*?)(?=^## \[|^\[[^\]]+\]: |\Z)", text, re.S | re.M)
sys.stdout.write("\n" + m.group(1).strip() + "\n")
' "$VERSION" > "$NOTES"
gh release create "$TAG" "$WIN_ZIP" "$ASHITA_ZIP" --verify-tag --latest --title "VanaTell $VERSION" --notes-file "$NOTES"

# 5. The site's download cache key, then the deploy.
sed -E -i '' "s/\\?vanatell-tag=v[0-9]+\\.[0-9]+\\.[0-9]+\"/?vanatell-tag=$TAG\"/" "$SITE/src/index.ts"
grep -q "?vanatell-tag=$TAG\"" "$SITE/src/index.ts" || die "the cache key in $SITE/src/index.ts was not bumped"
echo "release: deploying the site"
wrangler deploy

# 6. From outside, as an addon and a browser see it.
echo "release: checking $SITE_URL"
python3 -I - "$SITE_URL" "$OUT/latest.json" "$TAG" <<'PY'
import hashlib, http.client, json, sys, time, urllib.request
base, manifest_path, tag = sys.argv[1:]
want = json.load(open(manifest_path))
UA = {'User-Agent': 'vanatell-release'}

def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as r:
        return r.status, r.read()

for attempt in range(10):
    status, body = get(base + '/addon/latest.json')
    if status == 200 and json.loads(body) == want:
        break
    time.sleep(6)
else:
    sys.exit('release: %s/addon/latest.json is not the new manifest' % base)
n = 0
for platform in ('windower', 'ashita'):
    for f in want[platform]['files']:
        url = '%s/addon/%s/%s/%s' % (base, tag, platform, f['path'])
        status, body = get(url)
        if status != 200 or len(body) != f['size'] or hashlib.sha256(body).hexdigest() != f['sha256']:
            sys.exit('release: %s does not match the manifest' % url)
        n += 1
host = base.split('://', 1)[1]
for path, zip_name in (('/download/addon', 'vanatell-%s.zip' % tag), ('/download/ashita', 'vanatell-ashita-%s.zip' % tag)):
    c = http.client.HTTPSConnection(host, timeout=30)
    c.request('GET', path, headers=UA)
    r = c.getresponse()
    location = r.getheader('location') or ''
    if r.status != 302 or not location.endswith('/download/%s/%s' % (tag, zip_name)):
        sys.exit('release: %s leads to %r, not %s' % (path, location, zip_name))
print('release: verified latest.json (%s), %d files by SHA-256 and size, and both download links' % (want['version'], n))
PY
echo "release: done. Commit and push the cache key change in $SITE/src/index.ts."
