# Sourced by package.sh and build.sh: finds the signing identity at run time,
# so nothing in the repo names a person or a team.
#
# resolve_sign_identity [release] sets SIGN_IDENTITY to ZETTY_SIGN_IDENTITY when
# that names a valid identity exactly (its SHA-1 hash or its full name), else
# to the SHA-1 hash of the one valid "Developer ID Application" certificate in
# the keychain. Signing by hash, not name: a renewed certificate keeps its
# name, and codesign refuses a name two valid certificates share. With
# `release`, the override must be a Developer ID Application identity too
# (notarization takes nothing else).
#
# Returns 0 on success; 1 when there is simply no Developer ID certificate (a
# contributor's Mac, where build.sh builds ad-hoc); 2 for anything else (a bad
# override, several certificates), which must stop the build. The reason is in
# SIGN_IDENTITY_ERROR.
resolve_sign_identity() {
  SIGN_IDENTITY=
  SIGN_IDENTITY_ERROR=
  _identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  if [ -n "${ZETTY_SIGN_IDENTITY:-}" ]; then
    # Lines read `  1) <hash> "<name>"`: an exact hash or an exact name, so a
    # fragment ("Apple", "valid") can't pass for an identity.
    _line=$(printf '%s\n' "$_identities" | awk -v want="$ZETTY_SIGN_IDENTITY" '
      / [0-9A-F]{40} "/ {
        name = $0; sub(/^[^"]*"/, "", name); sub(/"[^"]*$/, "", name)
        if ($2 == want || name == want) { print; exit }
      }')
    if [ -z "$_line" ]; then
      SIGN_IDENTITY_ERROR="ZETTY_SIGN_IDENTITY names no valid signing identity in the keychain (give its SHA-1 hash or its full name)"
      return 2
    fi
    if [ "${1:-}" = release ] && ! printf '%s' "$_line" | grep -qF '"Developer ID Application: '; then
      SIGN_IDENTITY_ERROR="ZETTY_SIGN_IDENTITY is not a Developer ID Application identity, which a release needs"
      return 2
    fi
    SIGN_IDENTITY=$ZETTY_SIGN_IDENTITY
    return 0
  fi
  # One certificate in two keychains is listed twice, under one hash.
  _found=$(printf '%s\n' "$_identities" | grep '"Developer ID Application: ' | awk '{print $2}' | sort -u || true)
  case $(printf '%s' "$_found" | grep -c . || true) in
    0) SIGN_IDENTITY_ERROR="no valid \"Developer ID Application\" certificate in the keychain"
       return 1 ;;
    1) SIGN_IDENTITY=$_found
       return 0 ;;
    *) SIGN_IDENTITY_ERROR="several Developer ID Application certificates (security find-identity -v -p codesigning) — pick one with ZETTY_SIGN_IDENTITY=<hash>"
       return 2 ;;
  esac
}
