#!/usr/bin/env bash
if [[ "${@---help}" =~ '--help' ]]; then
  >&2 cat <<HELP
Usage: return.sh MyBook.odm

Process an early return of an OverDrive book loan.
HELP
  exit 1
fi

# Read the EarlyReturnURL tag from the input odm file
EarlyReturnURL=$(xmlstarlet sel -t -v '/OverDriveMedia/EarlyReturnURL' "$1")
printf 'Using EarlyReturnURL=%s\n' "$EarlyReturnURL"

curl -A "OverDrive Media Console/3.7.0.28 iOS/10.3.3" "$EarlyReturnURL"
# that response doesn't have a newline, so one more superfluous log to clean up:
printf '\nFinished returning book\n'
