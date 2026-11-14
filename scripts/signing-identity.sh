# Sourced by package.sh and build.sh: finds the signing identity at run time,
# so nothing in the repo names a person or a team.
#
# resolve_sign_identity sets SIGN_IDENTITY to ZETTY_SIGN_IDENTITY when that is
# set and valid, else to the SHA-1 hash of the one valid "Developer ID
# Application" certificate in the keychain. Signing by hash, not name: a
# renewed certificate keeps its name, and codesign refuses a name two valid
# certificates share. On failure it returns 1 with the reason in
# SIGN_IDENTITY_ERROR.
resolve_sign_identity() {
  SIGN_IDENTITY=
  SIGN_IDENTITY_ERROR=
  if [ -n "${ZETTY_SIGN_IDENTITY:-}" ]; then
    if security find-identity -v -p codesigning | grep -qF "$ZETTY_SIGN_IDENTITY"; then
      SIGN_IDENTITY=$ZETTY_SIGN_IDENTITY
      return 0
    fi
    SIGN_IDENTITY_ERROR="ZETTY_SIGN_IDENTITY is not a valid signing identity in the keychain"
    return 1
  fi
  _found=$(security find-identity -v -p codesigning | grep '"Developer ID Application: ' || true)
  case $(printf '%s' "$_found" | grep -c . || true) in
    0) SIGN_IDENTITY_ERROR="no valid \"Developer ID Application\" certificate in the keychain"
       return 1 ;;
    1) SIGN_IDENTITY=$(printf '%s' "$_found" | awk '{print $2}')
       return 0 ;;
    *) SIGN_IDENTITY_ERROR="several Developer ID Application certificates (security find-identity -v -p codesigning) — pick one with ZETTY_SIGN_IDENTITY=<hash>"
       return 1 ;;
  esac
}
