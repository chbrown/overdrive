# OverDrive

OverDrive is great and distributes DRM-free MP3s instead of some fragile DRM-ridden monstrosity, which is awesome.
Way to go, Rakuten / OverDrive, fight the man!

Their "OverDrive Media Console" application on Mac OS X is pretty simple, but it's so simple I'm like, why have an app?

The shell script in this repository [`overdrive.sh`](overdrive.sh) takes a sequence of commands and a list of `.odm` files (which are just XML).


## Install

The following will install the main script to your `/usr/local/bin` folder and mark it executable:

    curl --compressed https://chbrown.github.io/overdrive/overdrive.sh > /usr/local/bin/overdrive
    chmod +x /usr/local/bin/overdrive

Assuming `/usr/local/bin` is on your `PATH`, you can now run `overdrive --help` to show all the options.


## Prerequisites

This script is tested (i.e., developed and used) on macOS with bash 4.4.
It depends on the following (potentially non-standard?) executables being available on your `PATH`:

* `curl`
* `uuid`
* `xmlstarlet`
* `iconv`
* `openssl`
* `base64`
* `tidy`


## Instructions

Download an OverDrive loan file from your library or wherever.
I'll assume that yours is called `Novel.odm`.

When you run `overdrive download Novel.odm`, the script performs the following actions:

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

### Returning

The OverDrive format makes "returning" a loan extremely simple.
All you have to do is request the URL specified by the `<EarlyReturnURL>` element in the loan file.
The `return` command does exactly that, e.g.:

    overdrive return Novel.odm

### Debugging

If you have trouble getting the script to run successfully, add the `--verbose` flag and retry, e.g.:

    overdrive download Novel.odm --verbose

This will call `set -x` to turn bash's `xtrace` option on,
which causes a trace of all commands to be printed to standard error,
prefixed with one or more `+` signs.

If that doesn't help you debug the problem,
[open an issue](https://github.com/chbrown/overdrive/issues/new),
including the full debug output (optimally as a [gist](https://gist.github.com/)),
and I'll try to help you out.


## Post-processing

The most up-to-date ID3(v2) tagging tool I've found is [`mutagen`](https://mutagen.readthedocs.io/),
which is used and maintained by the [Quod Libet](https://quodlibet.readthedocs.io/) audio player project.
It was the only tagger that let me set the Genre tag to an arbitrary string (like iTunes).

Unfortunately, it appears that iTunes always loads `.mp3`s as "Music" despite the Genre (there doesn't seem to be any way to import `.mp3`s into iTunes _as_ "Audiobooks", you have to open iTunes, "Get Info" for the intended songs, and set the "Media Kind" to "Audiobook" manually.


## License

Copyright © 2017 Christopher Brown. [MIT Licensed](https://chbrown.github.io/licenses/MIT/#2017).
