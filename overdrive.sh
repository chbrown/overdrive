#!/usr/bin/env bash

set -e # exit immediately on first error
set -o pipefail # propagate intermediate pipeline errors

# should match `git describe --tags` with clean working tree
VERSION=2.4.0

OMC=1.2.0
OS=10.11.6
# use same user agent as mobile app
UserAgent='OverDrive Media Console'

usage() {
  >&2 cat <<HELP
Usage: $(basename "$0") [-h|--help]
       $(basename "$0") --version
       $(basename "$0") command [command2 ...] book.odm [book2.odm ...]

Commands:
  download   Download the mp3s for an OverDrive book loan.
  return     Process an early return for an OverDrive book loan.
  info       Print the author, title, and total duration (in seconds) for each OverDrive loan file.
  metadata   Print all metadata from each OverDrive loan file.

Options:
  -v|--verbose            Print shell calls to stderr and un-silent curl.
  -o|--output DIR_FORMAT  Specify the name of the directory to download to.
                          All instances of '@AUTHOR' and '@TITLE' are replaced with
                          the corresponding values extracted from the metadata.
                          Default: '@AUTHOR - @TITLE'.
HELP
}

MEDIA=()
COMMANDS=()
CURLOPTS=(-s -L -A "$UserAgent" --compressed --retry 3)
DIR_FORMAT='@AUTHOR - @TITLE'
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
    --insecure)
      CURLOPTS+=("$1")
      ;;
    -o|--output)
      shift
      DIR_FORMAT=$1
      ;;
    *.odm)
      if [[ ! -e $1 ]]; then
        >&2 printf 'Specified media file does not exist: %s\n' "$1"
        exit 2 # ENOENT 2 No such file or directory
      fi
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

for PREREQ in curl uuidgen xmllint iconv openssl base64; do
  if ! command -v $PREREQ >/dev/null 2>&1; then
    >&2 printf 'Cannot locate required executable "%s". ' $PREREQ
    >&2 printf 'This will likely result in an error later on, '
    >&2 printf 'which might leave you in an inconsistent failure state, '
    >&2 printf 'but continuing anyway.\n'
  fi
done

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
  if [[ $count -gt 0 ]]; then
    for i in $(seq 1 "$count"); do
      # xmllint does not reliably emit newlines, so we use command substitution to
      # trim trailing newlines, if there are any, and printf to add exactly one.
      printf '%s\n' "$(xmllint --xpath "string($1[position()=$i]$3)" "$2")"
    done
  fi
}

acquire_license() {
  # Usage: acquire_license book.odm book.license
  #
  # Read the license signature from book.license if it exists; if it doesn't,
  # acquire a license from the OverDrive server and write it to book.license.
  # We store the license in a file because OverDrive will only grant one license per `.odm` file,
  # so that if something goes wrong later on, like your internet cuts out mid-download,
  # it's easy to resume/recover where you left off.
  if [[ -s $2 ]]; then
    >&2 printf 'License already acquired: %s\n' "$2"
  else
    # generate random Client (GU)ID
    ClientID=$(uuidgen | tr '[:lower:]' '[:upper:]')
    >&2 printf 'Generating random ClientID=%s\n' "$ClientID"

    # first extract the "AcquisitionUrl"
    AcquisitionUrl=$(xmllint --xpath '/OverDriveMedia/License/AcquisitionUrl/text()' "$1")
    >&2 printf 'Using AcquisitionUrl=%s\n' "$AcquisitionUrl"
    # along with the only other important (for getting the license) field, "MediaID"
    MediaID=$(xmllint --xpath 'string(/OverDriveMedia/@id)' "$1")
    >&2 printf 'Using MediaID=%s\n' "$MediaID"

    # Compute the Base64-encoded SHA-1 hash from a few `|`-separated values
    # and a suffix of `OVERDRIVE*MEDIA*CONSOLE`, but backwards.
    # Thanks to https://github.com/jvolkening/gloc/blob/v0.601/gloc#L1523-L1531
    # for somehow figuring out how to construct that hash!
    RawHash="$ClientID|$OMC|$OS|ELOSNOC*AIDEM*EVIRDREVO"
    >&2 printf 'Using RawHash=%s\n' "$RawHash"
    Hash=$(echo -n "$RawHash" | iconv -f ASCII -t UTF-16LE | openssl dgst -binary -sha1 | base64)
    >&2 printf 'Using Hash=%s\n' "$Hash"

    # Submit a request to the OverDrive server to get the full license for this book,
    # which is a small XML file with a root element <License>,
    # which contains a long Base64-encoded <Signature>,
    # which is subsequently used to retrieve the content files.
    http_code=$(curl "${CURLOPTS[@]}" -o "$2" -w '%{http_code}' \
      "$AcquisitionUrl?MediaID=$MediaID&ClientID=$ClientID&OMC=$OMC&OS=$OS&Hash=$Hash")
    # if server responded with something besides an HTTP 200 OK (or other 2** success code),
    # print the failure response to stderr and delete the (invalid) file
    if [[ $http_code != 2?? ]]; then
      >&2 cat "$2"
      rm "$2"
      exit 22  # curl's exit code for "HTTP page not retrieved"
    fi
  fi
}

extract_metadata() {
  # Usage: extract_metadata book.odm book.metadata
  #
  # The Metadata XML is nested as CDATA inside the the root OverDriveMedia element;
  # luckily, it's the only text content at that level
  # sed: delete CDATA prefix from beginning of first line and suffix from end of last line,
  # replace unescaped & characters with &amp; entities,
  # and convert a selection of named HTML entities to their decimal code points
  if [[ -s $2 ]]; then
    : # >&2 printf 'Metadata already extracted: %s\n' "$2"
  else
    xmllint --noblanks --xpath '/OverDriveMedia/text()' "$1" \
    | sed -e '1s/^<!\[CDATA\[//' -e '$s/]]>$//' \
          -e 's/ & / \&amp; /g' \
          -e 's/&nbsp;/\&#160;/g' \
          -e 's/&iexcl;/\&#161;/g' \
          -e 's/&cent;/\&#162;/g' \
          -e 's/&pound;/\&#163;/g' \
          -e 's/&yen;/\&#165;/g' \
          -e 's/&sect;/\&#167;/g' \
          -e 's/&copy;/\&#169;/g' \
          -e 's/&ordf;/\&#170;/g' \
          -e 's/&laquo;/\&#171;/g' \
          -e 's/&reg;/\&#174;/g' \
          -e 's/&deg;/\&#176;/g' \
          -e 's/&sup2;/\&#178;/g' \
          -e 's/&sup3;/\&#179;/g' \
          -e 's/&para;/\&#182;/g' \
          -e 's/&ordm;/\&#186;/g' \
          -e 's/&raquo;/\&#187;/g' \
          -e 's/&iquest;/\&#191;/g' \
          -e 's/&Agrave;/\&#192;/g' \
          -e 's/&Aacute;/\&#193;/g' \
          -e 's/&Aring;/\&#197;/g' \
          -e 's/&AElig;/\&#198;/g' \
          -e 's/&Ccedil;/\&#199;/g' \
          -e 's/&Egrave;/\&#200;/g' \
          -e 's/&Eacute;/\&#201;/g' \
          -e 's/&Igrave;/\&#204;/g' \
          -e 's/&Iacute;/\&#205;/g' \
          -e 's/&Ograve;/\&#210;/g' \
          -e 's/&Oacute;/\&#211;/g' \
          -e 's/&Ouml;/\&#214;/g' \
          -e 's/&times;/\&#215;/g' \
          -e 's/&Oslash;/\&#216;/g' \
          -e 's/&Ugrave;/\&#217;/g' \
          -e 's/&Uacute;/\&#218;/g' \
          -e 's/&Uuml;/\&#220;/g' \
          -e 's/&Yacute;/\&#221;/g' \
          -e 's/&agrave;/\&#224;/g' \
          -e 's/&aacute;/\&#225;/g' \
          -e 's/&egrave;/\&#232;/g' \
          -e 's/&eacute;/\&#233;/g' \
          -e 's/&igrave;/\&#236;/g' \
          -e 's/&iacute;/\&#237;/g' \
          -e 's/&ograve;/\&#242;/g' \
          -e 's/&oacute;/\&#243;/g' \
          -e 's/&ouml;/\&#246;/g' \
          -e 's/&ugrave;/\&#249;/g' \
          -e 's/&uacute;/\&#250;/g' \
          -e 's/&uuml;/\&#252;/g' \
          -e 's/&yacute;/\&#253;/g' \
          -e 's/&thorn;/\&#254;/g' \
          -e 's/&Scaron;/\&#352;/g' \
          -e 's/&scaron;/\&#353;/g' \
          -e 's/&ndash;/\&#8211;/g' \
          -e 's/&mdash;/\&#8212;/g' \
          -e 's/&lsquo;/\&#8216;/g' \
          -e 's/&rsquo;/\&#8217;/g' \
          -e 's/&ldquo;/\&#8220;/g' \
          -e 's/&rdquo;/\&#8221;/g' \
          -e 's/&bull;/\&#8226;/g' \
          -e 's/&hellip;/\&#8230;/g' \
          -e 's/&euro;/\&#8364;/g' \
    > "$2"
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
  _xmllint_iter_xpath '//CoverUrl' "$1" '/text()' \
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

  # extract the author and title from the metadata
  Author=$(extract_author "$metadata_path")
  >&2 printf 'Using Author=%s\n' "$Author"
  Title=$(extract_title "$metadata_path")
  >&2 printf 'Using Title=%s\n' "$Title"

  # prepare to download the parts
  baseurl=$(xmllint --xpath 'string(//Protocol[@method="download"]/@baseurl)' "$1")

  # process substitutions in output directory pattern
  dir="${DIR_FORMAT//@AUTHOR/$Author}"
  dir="${dir//@TITLE/$Title}"
  >&2 printf 'Creating directory %s\n' "$dir"
  mkdir -p "$dir"

  # For each of the parts of the book listed in `Novel.odm`, make a request to another OverDrive endpoint,
  # which will validate the request and redirect to the actual MP3 file on their CDN,
  # and save the result into a folder in the current directory, named like `dir/Part0N.mp3`.
  for path in $(extract_filenames "$1"); do
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
  done

  # Loop over CoverUrl(s), since there may be none
  for CoverUrl in $(extract_coverUrl "$metadata_path" | head -1); do
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
  done
}

early_return() {
  # Usage: early_return book.odm
  #
  # return is a bash keyword, so we can't use that as the name of the function :(

  # Read the EarlyReturnURL tag from the input odm file
  EarlyReturnURL=$(xmllint --xpath '/OverDriveMedia/EarlyReturnURL/text()' "$1")
  >&2 printf 'Using EarlyReturnURL=%s\n' "$EarlyReturnURL"

  # now all we have to do is hit that URL
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
