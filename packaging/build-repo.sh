#!/bin/sh
# Build signed apt + yum repositories from prebuilt .deb/.rpm files, laid out
# as a static site suitable for GitHub Pages.
#
# Inputs (env vars, with defaults):
#   DIST            directory containing the .deb and .rpm files   (./dist)
#   OUT             output site directory                          (./site)
#   GPG_KEY         signing key id or email (must be in keyring)   (first secret key)
#   GPG_PASSPHRASE  passphrase for the key, if any                 (empty)
#   BASE_URL        public URL the site will be served from
#                   (https://tuncaybahadir.github.io/alabofur)
#
# Requires: dpkg-dev (dpkg-scanpackages), apt-utils (apt-ftparchive),
#           createrepo_c, gnupg.
set -eu

DIST="${DIST:-./dist}"
OUT="${OUT:-./site}"
BASE_URL="${BASE_URL:-https://tuncaybahadir.github.io/alabofur}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"

if [ -z "${GPG_KEY:-}" ]; then
    GPG_KEY=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')
fi
[ -n "$GPG_KEY" ] || { echo "no GPG signing key found"; exit 1; }

# gpg wrapper for non-interactive (CI) signing
gpg_sign() {
    if [ -n "$GPG_PASSPHRASE" ]; then
        gpg --batch --yes --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
            --local-user "$GPG_KEY" "$@"
    else
        gpg --batch --yes --pinentry-mode loopback --local-user "$GPG_KEY" "$@"
    fi
}

echo ">> signing key: $GPG_KEY"
echo ">> base url:    $BASE_URL"

rm -rf "$OUT"
mkdir -p "$OUT/deb" "$OUT/rpm"

# Public key (armored) that clients import for both repos.
gpg --armor --export "$GPG_KEY" > "$OUT/alabofur.asc"

# ---------------------------------------------------------------------------
# apt: flat repository ( deb [signed-by=...] BASE/deb ./ )
# ---------------------------------------------------------------------------
echo ">> building apt repo"
cp "$DIST"/*.deb "$OUT/deb/"
( cd "$OUT/deb"
  dpkg-scanpackages --multiversion . /dev/null > Packages
  gzip -9c Packages > Packages.gz
  apt-ftparchive \
      -o "APT::FTPArchive::Release::Origin=alabofur" \
      -o "APT::FTPArchive::Release::Label=alabofur" \
      -o "APT::FTPArchive::Release::Suite=stable" \
      -o "APT::FTPArchive::Release::Codename=stable" \
      -o "APT::FTPArchive::Release::Architectures=all" \
      -o "APT::FTPArchive::Release::Components=main" \
      release . > Release
)
gpg_sign --clearsign  -o "$OUT/deb/InRelease"  "$OUT/deb/Release"
gpg_sign --detach-sign -o "$OUT/deb/Release.gpg" "$OUT/deb/Release"

# ---------------------------------------------------------------------------
# yum: repodata with signed repomd.xml ( repo_gpgcheck=1 )
# ---------------------------------------------------------------------------
echo ">> building yum repo"
cp "$DIST"/*.rpm "$OUT/rpm/"
createrepo_c --quiet "$OUT/rpm"
gpg_sign --armor --detach-sign -o "$OUT/rpm/repodata/repomd.xml.asc" "$OUT/rpm/repodata/repomd.xml"

# Client .repo file
cat > "$OUT/rpm/alabofur.repo" <<EOF
[alabofur]
name=alabofur
baseurl=$BASE_URL/rpm
enabled=1
repo_gpgcheck=1
gpgcheck=0
gpgkey=$BASE_URL/alabofur.asc
EOF

# ---------------------------------------------------------------------------
# landing page with copy-paste install instructions
# ---------------------------------------------------------------------------
cat > "$OUT/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>alabofur — install</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem;color:#222}
h1{margin-bottom:.2rem}code,pre{background:#f4f4f4;border-radius:6px}
pre{padding:1rem;overflow:auto}code{padding:.1rem .3rem}</style></head><body>
<h1>alabofur</h1>
<p>Simple bandwidth shaper with a ufw-like UX.</p>

<h2>Debian / Ubuntu (apt)</h2>
<pre>curl -fsSL $BASE_URL/alabofur.asc | sudo gpg --dearmor -o /usr/share/keyrings/alabofur.gpg
echo "deb [signed-by=/usr/share/keyrings/alabofur.gpg] $BASE_URL/deb ./" | sudo tee /etc/apt/sources.list.d/alabofur.list
sudo apt update &amp;&amp; sudo apt install alabofur</pre>

<h2>Fedora / RHEL / CentOS (dnf/yum)</h2>
<pre>sudo curl -fsSL $BASE_URL/rpm/alabofur.repo -o /etc/yum.repos.d/alabofur.repo
sudo rpm --import $BASE_URL/alabofur.asc
sudo dnf install alabofur</pre>

<h2>Direct download</h2>
<p>Grab the <code>.deb</code> / <code>.rpm</code> from
<a href="https://github.com/tuncaybahadir/alabofur/releases">GitHub Releases</a>.</p>
</body></html>
EOF

# Pages: skip Jekyll processing so directories like repodata/ are served as-is.
: > "$OUT/.nojekyll"

echo ">> done. site tree:"
find "$OUT" -type f | sort | sed "s#^$OUT#  #"
