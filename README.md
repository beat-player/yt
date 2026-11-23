# yt

Downloads audio from YouTube. Uses [QuickJS-ng](https://github.com/quickjs-ng/quickjs) (through [`js`](https://github.com/beat-player/js)) to solve YouTube's player challenges, with [yt-dlp's solver scripts](https://github.com/yt-dlp/ejs).

## Usage

### Lua

```sh
lde add yt
```

```lua
local yt = require("yt")

local dl = yt.new({ cacheDir = "cache" }) -- cacheDir is optional; it keeps solved players between runs
local path, err = dl:downloadAudio("https://youtu.be/jNQXAC9IVRw", "music")

-- or step by step
local info = assert(dl:info("jNQXAC9IVRw")) -- id, title, author, duration, formats
local format = yt.bestAudio(info, "webm") -- "webm" (Opus) or "m4a" (AAC)
assert(dl:download(format, "zoo.webm", function(received, total) end))
```

Every call blocks, so run it off your UI thread.

### Command line

```sh
lde compile
./yt https://youtu.be/jNQXAC9IVRw music/
```

### C

```sh
lde compile --shared
```

```c
const char *yt_download(const char *input, const char *dir, const char *cache_dir); // path, or NULL
const char *yt_info(const char *input, const char *cache_dir);                     // JSON, or NULL
const char *yt_error(void);                                                       // why the last call failed
```

`cache_dir` may be `NULL`. A returned string stays valid until the next call of the same function. Don't call into the library from two threads at once. See [tests/c/download.c](tests/c/download.c) for a full example.

## Size

These are Linux x86-64 numbers:

| | Size |
|---|---|
| `lde compile --shared` (`libyt.so`, includes LuaJIT, libcurl and QuickJS) | 3.2 MB (1.5 MB gzipped) |
| `lde compile` (executable) | 3.2 MB |
| What it adds to an lde app that already ships curl-sys and json | ~1.3 MB: QuickJS 1.09 MB, solver scripts 159 kB, Lua ~20 kB |

For comparison, yt-dlp's standalone Linux build is 41 MB, and it also needs a JS runtime such as Deno (104 MB) for YouTube.

## How it works

1. Asks YouTube's internal API for the video as the `visionos` client. Its stream URLs need no JavaScript.
2. If that fails, it asks as `tv_samsung`, whose URLs carry challenges. It solves them by running yt-dlp's ejs scripts on YouTube's player in QuickJS. The first solve of a new player takes a few seconds. After that it's cached and takes well under a second.
3. Downloads in 10 MiB ranges after any pre-roll ad time YouTube enforces.

When YouTube breaks something, the fix usually lives in yt-dlp. Copy client changes from its `INNERTUBE_CLIENTS` into `src/innertube.lua`, and bump `EJS_VERSION` in `build.lua` for new solver scripts.

## Tests

`lde test` runs offline unit tests. It also downloads a real video through each entry point: the Lua API, the compiled command line, and the shared library from C. These need network access and a C compiler.
