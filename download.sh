#!/usr/bin/env bash
if [[ "${@---help}" =~ '--help' ]]; then
  >&2 cat <<HELP
Usage: download.sh MyBook.odm

Download the mp3s for an OverDrive book loan.
HELP
  exit 1
fi

# exit on first error
set -e

if [[ -n "$DEBUG" ]]; then
  printf "Entering debug (verbose) mode\n"
  set -x
fi

OMC=1.2.0
OS=10.11.6

# fake user agent to match app's
UserAgent="OverDrive Media Console"

# the input odm file
odm="$1"

# get the license signature
if [[ -e "$odm.license" ]]; then
  printf "License already acquired: %s\n" "$odm.license"
else
  # generate random Client ID
  ClientID=$(uuid | tr /a-z/ /A-Z/)
  printf "Generating random ClientID=%s\n" "$ClientID"

  # first extract the "AcquisitionUrl"
  AcquisitionUrl=$(xmlstarlet sel -t -v '/OverDriveMedia/License/AcquisitionUrl' "$odm")
  printf "Using AcquisitionUrl=%s\n" "$AcquisitionUrl"

  MediaID=$(xmlstarlet sel -t -v '/OverDriveMedia/@id' "$odm")
  printf "Using MediaID=%s\n" "$MediaID"

  # Compute the Hash value; thanks to https://github.com/jvolkening/gloc/blob/v0.601/gloc#L1523-L1531
  RawHash="$ClientID|$OMC|$OS|ELOSNOC*AIDEM*EVIRDREVO"
  printf "Using RawHash=%s\n" "$RawHash"
  Hash=$(echo -n "$RawHash" | iconv -f ASCII -t UTF-16LE | openssl dgst -binary -sha1 | base64)
  printf "Using Hash=%s\n" "$Hash"

  curl -A "$UserAgent" "$AcquisitionUrl?MediaID=$MediaID&ClientID=$ClientID&OMC=$OMC&OS=$OS&Hash=$Hash" > "$odm.license"
fi
License=$(cat "$odm.license")
printf "Using License=%s\n" "$License"

# the license XML specifies a default namespace, which the XPath expression must also reference
ClientID=$(xmlstarlet sel -N ol=http://license.overdrive.com/2008/03/License.xsd -t -v '/ol:License/ol:SignedInfo/ol:ClientID' "$odm.license")
printf "Using ClientID=%s from License\n" "$ClientID"

extractMetadata() {
  # the Metadata XML is nested as CDATA inside the the root OverDriveMedia element;
  # luckily, it's the only text content at that level
  # N.b.: tidy will still write errors & warnings to /dev/stderr, despite the -quiet
  xmlstarlet sel -T text -t -v '/OverDriveMedia/text()' "$1" | tidy -xml -wrap 0 -quiet
}

# extract the title and author
Title=$(extractMetadata "$odm" | xmlstarlet sel -t -v '//Title' | tr -Cs '[:alnum:] ._-' -)
printf "Using Title=%s\n" "$Title"
Author=$(extractMetadata "$odm" | xmlstarlet sel -t -v "//Creator[@role='Author'][position()<=3]/text()" | tr '\n' + | sed 's/+/, /g')
printf "Using Author=%s\n" "$Author"

# prepare to download the parts
baseurl=$(xmlstarlet sel -t -v '//Protocol[@method="download"]/@baseurl' "$odm")

dir="$Author - $Title"
printf "Creating directory %s\n" "$dir"
mkdir -p "$dir"

while read -r path; do
  # delete from path up until the last hyphen to the get Part0N.mp3 suffix
  suffix=${path##*-}
  output="$dir/$Title-$suffix"
  printf "Downloading %s\n" "$output"
  curl -L \
    -A "$UserAgent" \
    -H "License: $License" \
    -H "ClientID: $ClientID" \
    --compressed -o "$output" \
    "$baseurl/$path"
done < <(xmlstarlet sel -t -v '//Part/@filename' "$odm" | tr '\\' / | sed -e "s/{/%7B/" -e "s/}/%7D/")
