# OverDrive

OverDrive is great and distributes DRM-free MP3s instead of some fragile DRM-ridden format, which is awesome.
Way to go, Rakuten / OverDrive, fight the man!

Their "OverDrive Media Console" application for macOS is pretty simple...
so simple, I'm like, why have an app?

So I wrote a shell script, [`overdrive.sh`](overdrive.sh),
which takes one or more `.odm` files (which are just XML),
and downloads the audio content files locally, just like the app.


## Install

The following will install the standalone script into `~/.local/bin` and mark it executable:

```sh
mkdir -p ~/.local/bin
curl https://chbrown.github.io/overdrive/overdrive.sh -o ~/.local/bin/overdrive
chmod +x ~/.local/bin/overdrive
```

At this point, if calling `overdrive` produces the error message `-bash: overdrive: command not found`,
you'll need to add `~/.local/bin` to your `PATH`. One way to do this:

```sh
printf 'export PATH=$HOME/.local/bin:$PATH\n' >> ~/.bashrc
source ~/.bashrc
```

**_N.b.:_ if you're using `zsh`** instead of `bash`, run this instead:

```sh
printf 'export PATH=$HOME/.local/bin:$PATH\n' >> ~/.zshrc
source ~/.zshrc
```

Now you should be able to run `overdrive --help` and use the commands described below...


## Instructions

Download an OverDrive loan file from your library or wherever.
I'll assume that yours is called `Novel.odm`.
Assuming you've downloaded it to your `~/Downloads` folder, simply run the following command:

    cd ~/Downloads
    overdrive download Novel.odm

When you run that, the script first checks if there is already a `Novel.odm.license` file alongside `Novel.odm`.
If that file already exists, the script will not request a new license,
since the OverDrive server will only grant one license per `.odm` loan.
If not, it will request the license from the OverDrive server and write it to a new `Novel.odm.license` file,
by performing the following actions:

1. Extract the `AcquisitionUrl` and `MediaID` from the `Novel.odm` file.
2. Compute a Base64-encoded SHA-1 hash from a few `|`-separated values
   and a suffix of `OVERDRIVE*MEDIA*CONSOLE`, but backwards.
   (Thanks to https://github.com/jvolkening/gloc for somehow figuring out how to construct that hash!)
3. Using those values and a randomly generated `ClientID` GUID,
   it submits a request to the OverDrive server to get the full license for this book,
   which is an XML file that has a `<License>` element at the root.
   That element contains a long Base64-encoded `<Signature>`,
   which is subsequently used to request the content files.

Now, license in hand, the script downloads the audio content files by taking the following steps:

4. Extract the `Title` and `Author` values from the `CDATA` content nested in `Novel.odm`.
5. For each of the parts of the book listed in `Novel.odm`, make a request to another OverDrive endpoint,
   which will validate the request and redirect to the actual MP3 file on their CDN,
   and save the result into a folder in the current directory, named like `Author - Title/Title-Part0N.mp3`.


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


#### Prerequisites

This script is tested (i.e., developed and used) on macOS with bash 5.0.
It depends on the following executables being available on your `PATH`:

* `curl`
* `uuidgen`
* `xmllint`
* `iconv`
* `openssl`
* `base64`
* `tidy`

To run in alpine (e.g. with Docker), install the prerequisites with:

`apk update && apk add bash curl util-linux libxml2-utils openssl tidyhtml`


## Post-processing

The most up-to-date ID3(v2) tagging tool I've found is [`mutagen`](https://mutagen.readthedocs.io/),
which is used and maintained by the [Quod Libet](https://quodlibet.readthedocs.io/) audio player project.
It was the only tagger that let me set the Genre tag to an arbitrary string (like iTunes).

Unfortunately, it appears that iTunes always loads `.mp3`s as "Music" despite the Genre
(there doesn't seem to be any way to import `.mp3`s into iTunes _as_ "Audiobooks",
you have to open iTunes, "Get Info" for the intended songs, and set the "Media Kind" to "Audiobook" manually.


## License

Copyright © 2017–2020 Christopher Brown.
[MIT Licensed](https://chbrown.github.io/licenses/MIT/#2017-2020).
