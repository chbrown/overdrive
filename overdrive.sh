#!/usr/bin/env bash

set -e # exit immediately on first error

# should match `git describe --tags` with clean working tree
VERSION=2.1.1

OMC=1.2.0
OS=10.11.6
# use same user agent as mobile app
UserAgent='OverDrive Media Console'

usage() {
  >&2 cat <<HELP
Usage: $(basename "$0") [-h|--help]
       $(basename "$0") --version
       $(basename "$0") command [command2 ...] book.odm [book2.odm ...] [-v|--verbose]

Commands:
  download   Download the mp3s for an OverDrive book loan.
  return     Process an early return for an OverDrive book loan.
  info       Print the author, title, and total duration (in seconds) for each OverDrive loan file.
  metadata   Print all metadata from each OverDrive loan file.
HELP
}

MEDIA=()
COMMANDS=()
CURLOPTS=(-s -L -A "$UserAgent" --compressed)
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    --version)
      >&2 printf '%s\n' "$VERSION"
      exit 0
      ;;
    -v|--verbose)
      >&2 printf 'Entering debug (verbose) mode\n'
      set -x
      CURLOPTS=("${CURLOPTS[@]:1}") # slice off the '-s'
      ;;
    *.odm)
      MEDIA+=("$1")
      ;;
    download|return|info|metadata)
      COMMANDS+=("$1")
      ;;
    *)
      >&2 printf 'Unrecognized argument: %s\n' "$1"
      exit 1
      ;;
  esac
  shift
done

if [[ ${#MEDIA[@]} -eq 0 || ${#COMMANDS[@]} -eq 0 ]]; then
  usage
  >&2 printf '\n'
  [[ ${#COMMANDS[@]} -eq 0 ]] && >&2 printf 'You must supply at least one command.\n'
  [[ ${#MEDIA[@]} -eq 0 ]] && >&2 printf 'You must supply at least one media file (the .odm extension is required).\n'
  exit 1
fi

_sanitize() {
  # Usage: printf 'Hello, world!\n' | _sanitize
  #
  # Replace filename-unfriendly characters with a hyphen and trim leading/trailing hyphens/spaces
  tr -Cs '[:alnum:] ._-' - | sed -e 's/^[- ]*//' -e 's/[- ]*$//'
}

_xmllint_iter_xpath() {
  # Usage: _xmllint_iter_xpath /xpath/to/list file.xml [/path/to/value]
  #
  # Iterate over each XPath match, ensuring each ends with exactly one newline.
  count=$(xmllint --xpath "count($1)" "$2")
  for i in $(seq 1 "$count"); do
    # xmllint does not reliably emit newlines, so we use command substitution to
    # trim trailing newlines, if there are any, and printf to add exactly one.
    printf '%s\n' "$(xmllint --xpath "string($1[position()=$i]$3)" "$2")"
  done
}

acquire_license() {
  # Usage: acquire_license book.odm book.license
  #
  # Read the license signature from book.license if it exists; if it doesn't,
  # acquire a license from the OverDrive server and write it to book.license.
  if [[ -e $2 ]]; then
    >&2 printf 'License already acquired: %s\n' "$2"
  else
    # generate random Client ID
    ClientID=$(uuidgen | tr '[:lower:]' '[:upper:]')
    >&2 printf 'Generating random ClientID=%s\n' "$ClientID"

    # first extract the "AcquisitionUrl"
    AcquisitionUrl=$(xmllint --xpath '/OverDriveMedia/License/AcquisitionUrl/text()' "$1")
    >&2 printf 'Using AcquisitionUrl=%s\n' "$AcquisitionUrl"

    MediaID=$(xmllint --xpath 'string(/OverDriveMedia/@id)' "$1")
    >&2 printf 'Using MediaID=%s\n' "$MediaID"

    # Compute the Hash value; thanks to https://github.com/jvolkening/gloc/blob/v0.601/gloc#L1523-L1531
    RawHash="$ClientID|$OMC|$OS|ELOSNOC*AIDEM*EVIRDREVO"
    >&2 printf 'Using RawHash=%s\n' "$RawHash"
    Hash=$(echo -n "$RawHash" | iconv -f ASCII -t UTF-16LE | openssl dgst -binary -sha1 | base64)
    >&2 printf 'Using Hash=%s\n' "$Hash"

    curl "${CURLOPTS[@]}" "$AcquisitionUrl?MediaID=$MediaID&ClientID=$ClientID&OMC=$OMC&OS=$OS&Hash=$Hash" > "$2"
  fi
}

extract_metadata() {
  # Usage: extract_metadata book.odm book.metadata
  #
  # The Metadata XML is nested as CDATA inside the the root OverDriveMedia element;
  # luckily, it's the only text content at that level
  # sed: delete CDATA prefix from beginning of first line, and suffix from end of last line
  # N.b.: tidy will still write errors & warnings to /dev/stderr, despite the -quiet
  if [[ -e $2 ]]; then
    : # >&2 printf 'Metadata already extracted: %s\n' "$2"
  else
    xmllint --noblanks --xpath '/OverDriveMedia/text()' "$1" \
    | sed -e '1s/^<!\[CDATA\[//' -e '$s/]]>$//' \
    | tidy -xml -wrap 0 -quiet > "$metadata_path" || true
  fi
}

extract_author() {
  # Usage: extract_author book.odm.metadata
  # Most Creator/@role values for authors are simply "Author" but some are "Author and narrator"
  xmllint --xpath "string(//Creator[starts-with(@role, 'Author')])" "$1"
}

extract_title() {
  # Usage: extract_title book.odm.metadata
  xmllint --xpath '//Title/text()' "$1" \
  | _sanitize
}

extract_duration() {
  # Usage: extract_duration book.odm
  #
  # awk: `-F :` split on colons; for MM:SS, MM=>$1, SS=>$2
  #      `$1*60 + $2` converts MM:SS into seconds
  #      `{sum += ...} END {print sum}` output total sum (seconds)
  _xmllint_iter_xpath '//Part' "$1" '/@duration' \
  | awk -F : '{sum += $1*60 + $2} END {print sum}'
}

extract_filenames() {
  # Usage: extract_filenames book.odm
  _xmllint_iter_xpath '//Part' "$1" '/@filename' \
  | sed -e "s/{/%7B/" -e "s/}/%7D/"
}

extract_coverUrl() {
  # Usage: extract_coverUrl book.odm.metadata
  xmllint --xpath '//CoverUrl/text()' "$1" \
  | sed -e "s/{/%7B/" -e "s/}/%7D/"
}

download() {
  # Usage: download book.odm
  #
  license_path=$1.license
  acquire_license "$1" "$license_path"
  >&2 printf 'Using License=%s\n' "$(cat "$license_path")"

  # the license XML specifies a default namespace, so the XPath is a bit awkward
  ClientID=$(xmllint --xpath '//*[local-name()="ClientID"]/text()' "$license_path")
  >&2 printf 'Using ClientID=%s from License\n' "$ClientID"

  # extract metadata
  metadata_path=$1.metadata
  extract_metadata "$1" "$metadata_path"

  # extract the author and title
  Author=$(extract_author "$metadata_path")
  >&2 printf 'Using Author=%s\n' "$Author"
  Title=$(extract_title "$metadata_path")
  >&2 printf 'Using Title=%s\n' "$Title"

  # prepare to download the parts
  baseurl=$(xmllint --xpath 'string(//Protocol[@method="download"]/@baseurl)' "$1")

  dir="$Author - $Title"
  >&2 printf 'Creating directory %s\n' "$dir"
  mkdir -p "$dir"

  while read -r path; do
    # delete from path up until the last hyphen to the get Part0N.mp3 suffix
    suffix=${path##*-}
    output="$dir/$suffix"
    if [[ -e $output ]]; then
      >&2 printf 'Output already exists: %s\n' "$output"
    else
      >&2 printf 'Downloading %s\n' "$output"
      if curl "${CURLOPTS[@]}" \
          -H "License: $(cat "$license_path")" \
          -H "ClientID: $ClientID" \
          -o "$output" \
          "$baseurl/$path"; then
        >&2 printf 'Downloaded %s successfully\n' "$output"
      else
        STATUS=$?
        >&2 printf 'Failed trying to download %s\n' "$output"
        rm -f "$output"
        return $STATUS
      fi
    fi
  done < <(extract_filenames "$1")

  CoverUrl=$(extract_coverUrl "$metadata_path")
  >&2 printf 'Using CoverUrl=%s\n' "$CoverUrl"
  if [[ -n "$CoverUrl" ]]; then
      cover_output=$dir/folder.jpg
      >&2 printf 'Downloading %s\n' "$cover_output"
      if curl "${CURLOPTS[@]}" \
          -o "$cover_output" \
          "$CoverUrl"; then
        >&2 printf 'Downloaded cover image successfully\n'
      else
        STATUS=$?
        >&2 printf 'Failed trying to download cover image\n'
        rm -f "$cover_output"
        return $STATUS
      fi
  else
    >&2 printf 'Cover image not available\n'
  fi
}

early_return() {
  # Usage: early_return book.odm
  #
  # return is a bash keyword, so we can't use that as the name of the function :(

  # Read the EarlyReturnURL tag from the input odm file
  EarlyReturnURL=$(xmllint --xpath '/OverDriveMedia/EarlyReturnURL/text()' "$1")
  >&2 printf 'Using EarlyReturnURL=%s\n' "$EarlyReturnURL"

  curl "${CURLOPTS[@]}" "$EarlyReturnURL"
  # that response doesn't have a newline, so one more superfluous log to clean up:
  >&2 printf '\nFinished returning book\n'
}

HEADER_PRINTED=
info() {
  # Usage: info book.odm
  if [[ -z $HEADER_PRINTED ]]; then
    printf '%s\t%s\t%s\n' author title duration
    HEADER_PRINTED=1
  fi
  metadata_path=$1.metadata
  extract_metadata "$1" "$metadata_path"
  printf '%s\t%s\t%d\n' "$(extract_author "$metadata_path")" "$(extract_title "$metadata_path")" "$(extract_duration "$1")"
}

metadata() {
  # Usage: metadata book.odm
  metadata_path=$1.metadata
  extract_metadata "$1" "$metadata_path"
  xmllint --format "$metadata_path" | sed 1d
}

# now actually loop over the media files and commands
for ODM in "${MEDIA[@]}"; do
  for COMMAND in "${COMMANDS[@]}"; do
    case $COMMAND in
      download)
        download "$ODM"
        ;;
      return)
        early_return "$ODM"
        ;;
      info)
        info "$ODM"
        ;;
      metadata)
        metadata "$ODM"
        ;;
      *)
        >&2 printf 'Unrecognized command: %s\n' "$COMMAND"
        exit 1
        ;;
    esac
  done
done
