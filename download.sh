#!/usr/bin/env bash
if [[ "${@---help}" =~ '--help' ]]; then
  >&2 cat <<HELP
Usage: download.sh MyBook.odm

Download the mp3s for an OverDrive book loan.
HELP
  exit 1
fi

OMC=1.2.0
OS=10.11.6

# fake user agent to match app's
UserAgent="OverDrive Media Console"

# the input odm file
odm="$1"

# generate random Client ID
ClientID=$(uuid | tr /a-z/ /A-Z/)
printf "Using ClientID=%s\n" "$ClientID"

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

# get the license signature
if [[ -e "$odm.license" ]]; then
  printf "License already acquired: %s\n" "$odm.license"
else
  curl -A "$UserAgent" "$AcquisitionUrl?MediaID=$MediaID&ClientID=$ClientID&OMC=$OMC&OS=$OS&Hash=$Hash" > "$odm.license"
fi
License=$(cat "$odm.license")
printf "Using License=%s\n" "$License"

# extract the title
Title=$(xmlstarlet sel -T text -t -v '/OverDriveMedia/text()' "$odm" | tidy -xml -quiet | xmlstarlet sel -t -v '//Title')
printf "Using Title=%s\n" "$Title"

# download the parts
baseurl=$(xmlstarlet sel -t -v '//Protocol[@method="download"]/@baseurl' "$odm")

while read -r path; do
  # delete from path up until the last hyphen to the get Part0N.mp3 suffix
  suffix=${path##*-}
  output="$Title-$suffix"
  printf "Downloading %s\n" "$output"
  curl -L \
    -A "$UserAgent" \
    -H "License: $License" \
    -H "ClientID: $ClientID" \
    --compressed -o "$output" \
    "$baseurl/$path"
done < <(xmlstarlet sel -t -v '//Part/@filename' "$odm" | tr \\ / | sed -e "s/{/%7B/" -e "s/}/%7D/")
