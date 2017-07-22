# OverDrive

OverDrive is great and distributes DRM-free MP3s instead of some fragile DRM-ridden monstrosity, which is awesome.
Way to go, Rakuten / OverDrive, fight the man!

Their "OverDrive Media Console" application on Mac OS X is pretty simple, but it's so simple I'm like, why have an app?

The shell script [`download.sh`](download.sh) takes a single argument, the path to an `.odm` file (which is XML), and downloads the corresponding files into the current directory.


## Instructions

Download an OverDrive loan file from your library or wherever.
I'll assume that yours is called `Novel.odm`.

You might want to change the hard-coded `ClientID` value.
The value must be in GUID format (I think?) but it doesn't matter what it is as long as the same ID is used for all the requests.

When you run `bash download.sh Novel.odm`, the script performs the following actions:

* Extract the `AcquisitionUrl` and `MediaID` from the `Novel.odm` file.
* Compute a Base64-encoded SHA-1 hash from a few `|`-separated values and a suffix of `OVERDRIVE*MEDIA*CONSOLE` but backwards.

  Thanks to https://github.com/jvolkening/gloc for somehow figuring out how to construct that hash.
* Using those values and the hard-coded `ClientID`, submit a request to the OverDrive server to get the full license for this book.

You'll now have a file `Novel.odm.license` in your current folder,
which is an XML file that has a `<License>` element at the root,
which contains a long Base64-encoded `<Signature>`.

(Now back to the script)

* Extract the `Title` value from the `CDATA` content nested in `Novel.odm`.
* For each of the parts of the book listed in `Novel.odm`, make a request to another OverDrive endpoint, which will validate the request and redirect to the actual MP3 file on their CDN, and save the result to a file named like `Title -Part0N.mp3`.


## License

Copyright © 2017 Christopher Brown. [MIT Licensed](https://chbrown.github.io/licenses/MIT/#2017).
