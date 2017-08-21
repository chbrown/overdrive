# OverDrive

OverDrive is great and distributes DRM-free MP3s instead of some fragile DRM-ridden monstrosity, which is awesome.
Way to go, Rakuten / OverDrive, fight the man!

Their "OverDrive Media Console" application on Mac OS X is pretty simple, but it's so simple I'm like, why have an app?

The shell script [`download.sh`](download.sh) takes a single argument, the path to an `.odm` file (which is XML), and downloads the corresponding files into the current directory.


## Instructions

Download an OverDrive loan file from your library or wherever.
I'll assume that yours is called `Novel.odm`.

When you run `bash download.sh Novel.odm`, the script performs the following actions:

* Extract the `AcquisitionUrl` and `MediaID` from the `Novel.odm` file.
* Compute a Base64-encoded SHA-1 hash from a few `|`-separated values and a suffix of `OVERDRIVE*MEDIA*CONSOLE` but backwards.

  Thanks to https://github.com/jvolkening/gloc for somehow figuring out how to construct that hash.
* Using those values and a random `ClientID` GUID, submit a request to the OverDrive server to get the full license for this book.

You'll now have a file `Novel.odm.license` in the same folder as the `Novel.odm` file,
which is an XML file that has a `<License>` element at the root,
which contains a long Base64-encoded `<Signature>`.

If that file already exists, the script will not request a new license, since the OverDrive server will only grant one license per `.odm` loan.

(Now back to the script)

* Extract the `Title` and `Author` values from the `CDATA` content nested in `Novel.odm`.
* For each of the parts of the book listed in `Novel.odm`, make a request to another OverDrive endpoint, which will validate the request and redirect to the actual MP3 file on their CDN, and save the result into a folder in the current directory, named like `Author - Title/Title-Part0N.mp3`.


## License

Copyright © 2017 Christopher Brown. [MIT Licensed](https://chbrown.github.io/licenses/MIT/#2017).
