#!/bin/bash
# Which "Developer ID Application" identity to sign with.
#
# Usage: scripts/developer-id-identity.sh [<team id>]
#
# Prints one tab-separated line, the identity to hand to `codesign --sign`:
#
#   <SHA-1>  <team>  <issuing authority's OU>  <expires, YYYY-MM-DD>  <common name>
#
# and nothing when the keychains hold no valid Developer ID Application identity (of that
# team): whether that is an error is the caller's to say. It fails when it cannot read the
# certificate of an identity it was told is valid, and when no team is given and the
# identities belong to more than one.
#
# The rule: a certificate issued by "Developer ID Certification Authority" G2 before one
# issued by the authority before it, then the one that expires last.
#
# Why there is a rule. Apple's original Developer ID authority expires on February 1, 2027,
# and every certificate it issued stops signing that day; replacements come from G2
# (developer.apple.com/help/account/certificates/replace-developer-id-certificates).
# So a Mac holds two valid identities around every renewal, and they have the same name.
# What tells them apart is the Organizational Unit of the issuer: "G2", or "Apple
# Certification Authority" for the previous one. `codesign --sign "<name>"` refuses a name
# two identities answer to, hence the SHA-1.
set -euo pipefail

want_team="${1:-}"
kind="Developer ID Application"

# `  2) <SHA-1> "Developer ID Application: <name> (<team>)"`. -v lists valid identities only:
# an expired or revoked certificate stays in the keychain and is never here.
identities="$(security find-identity -v -p codesigning | grep -F "\"$kind: " || true)"
[[ -n "$identities" ]] || exit 0
# Every certificate of that kind, each PEM under its own `SHA-1 hash:` line.
certificates="$(security find-certificate -a -Z -p -c "$kind")"

# awk reads to the end rather than exiting at the match: an early exit would close the pipe
# under printf, which `pipefail` reports as a failure.
pem_of() {
	printf '%s\n' "$certificates" | awk -v want="SHA-1 hash: $1" '
		/^SHA-1 hash: / { found = ($0 == want && !done) }
		found && /BEGIN CERTIFICATE/ { pem = 1 }
		pem { print }
		pem && /END CERTIFICATE/ { pem = 0; found = 0; done = 1 }'
}

# The OU of a `subject=` or `issuer=` line in either spelling: OpenSSL writes `…, OU=G2, …`,
# the LibreSSL that macOS ships writes `…/OU=G2/…`.
ou_of() { sed -n 's/.*OU *= *\([^,/]*\).*/\1/p'; }

# One row per identity: <1 for G2, else 0> <expiry, epoch> and then the line to print.
candidates() {
	local line hash name pem facts team authority not_after epoch rank
	while IFS= read -r line; do
		hash="$(printf '%s\n' "$line" | awk '{ print $2 }')"
		name="$(printf '%s\n' "$line" | sed -E 's/^[^"]*"(.*)"$/\1/')"
		pem="$(pem_of "$hash")"
		if [[ -z "$pem" ]]; then
			echo "developer-id-identity.sh: '$name' is a valid identity, but no certificate with SHA-1 $hash came back from: security find-certificate -a -Z -p -c '$kind'" >&2
			exit 1
		fi
		facts="$(printf '%s\n' "$pem" | openssl x509 -noout -subject -issuer -enddate)"
		team="$(printf '%s\n' "$facts" | sed -n '/^subject=/p' | ou_of)"
		authority="$(printf '%s\n' "$facts" | sed -n '/^issuer=/p' | ou_of)"
		not_after="$(printf '%s\n' "$facts" | sed -n 's/^notAfter=//p')"
		if [[ -z "$team" || -z "$authority" || -z "$not_after" ]]; then
			echo "developer-id-identity.sh: could not read the team, the issuer or the expiry of '$name' ($hash) out of:" >&2
			printf '%s\n' "$facts" | sed 's/^/    /' >&2
			exit 1
		fi
		[[ -z "$want_team" || "$team" == "$want_team" ]] || continue
		# `notAfter=Feb  1 22:12:15 2027 GMT`
		epoch="$(LC_ALL=C date -j -u -f '%b %e %T %Y %Z' "$not_after" +%s)"
		rank=0
		[[ "$authority" != "G2" ]] || rank=1
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rank" "$epoch" \
			"$hash" "$team" "$authority" "$(date -j -u -r "$epoch" +%Y-%m-%d)" "$name"
	done <<< "$identities"
}

rows="$(candidates)"
[[ -n "$rows" ]] || exit 0
teams="$(printf '%s\n' "$rows" | cut -f4 | sort -u)"
if [[ "$(printf '%s\n' "$teams" | grep -c .)" -gt 1 ]]; then
	echo "developer-id-identity.sh: the valid \"$kind\" identities belong to more than one team ($(printf '%s' "$teams" | tr '\n' ' ')); name the one to sign with: $0 <team id>" >&2
	exit 1
fi
printf '%s\n' "$rows" | sort -t "$(printf '\t')" -k1,1nr -k2,2nr -k3,3 | sed -n 1p | cut -f3-
