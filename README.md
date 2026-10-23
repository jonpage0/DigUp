<p align="center"><img src="docs/logo.png" width="96" alt=""></p>

<h1 align="center">DigUp</h1>

<p align="center"><b>Describe it. Dig it up.</b><br>
Search the files on your computer by what's in them, with Google DeepMind's
<a href="https://huggingface.co/google/embeddinggemma-2">EmbeddingGemma 2</a>.</p>

<p align="center"><a href="https://github.com/ARahim3/DigUp/releases/latest"><b>Download for Mac</b></a> ·
<a href="https://github.com/ARahim3/DigUp/releases/tag/v0.7.0-beta.2"><b>Windows (beta)</b></a> ·
<a href="https://github.com/ARahim3/DigUp/releases/tag/v0.7.0-beta.2"><b>Linux (beta)</b></a><br>
<sub>Free and open source. Everything runs on your computer.</sub></p>

> **This fork** of [ARahim3/DigUp](https://github.com/ARahim3/DigUp) adds Apple Photos libraries, read through
> [osxphotos](https://github.com/RhetTbull/osxphotos) (see [Apple Photos](#apple-photos)), and what's said in
> recordings, read through [parakeet-mlx](https://github.com/senstella/parakeet-mlx) (see [What's said](#whats-said)).
> The downloads above are upstream's and have neither. To build this fork, clone `https://github.com/jonpage0/DigUp`
> (branch `apple-photos`) and follow "Build from source" below.

<p align="center"><img src="docs/demo.gif" width="800" alt="DigUp's search panel on a Mac, on Windows and on Linux: a zebra in a video, a podcast minute, a clause in a lease, a dog on the beach in English, Bengali and Arabic, and code that opens in Zed."></p>

EmbeddingGemma 2 is the multimodal embedding model Google DeepMind released in October 2026. It puts text, images,
audio and video into one shared space: a photo of a dog on a beach lands next to the words "a dog on the beach", and a
recording of someone talking about sleep lands next to "where they talk about sleep". It understands more than 100
languages, it's open (Apache 2.0), and at 740M parameters it's small enough to run on a laptop.

DigUp brings that to the files on your computer, on a Mac, on Windows or on Linux. Pick the folders to search, and it
reads the pictures, PDFs, documents, recordings and videos in them. Then describe what you're looking for, in your own
words, and it finds the match, whatever kind of file it is.

## What you can find

- "zebra in a video" opens the clip at the moment the zebra shows up
- "where they talk about sleep" jumps to that minute of a podcast
- "where she says the flight is cancelled" finds that stretch of a recording, by the words said or by what they mean
  (on a Mac with parakeet-mlx: see [What's said](#whats-said))
- "the clause about pets in the lease" shows the PDF page
- "a dog on the beach" finds the photo, and "payment declined error" the screenshot
- a search in English can find a note written in Bengali, Arabic or any of the model's 100+ languages, and the other
  way around
- "code: retry a failed call with backoff" finds the function in your projects, if you turn on code search

Exact words count too. Invoice numbers, error codes and names are matched as written, in file names and document text,
so a search gets both the meaning and the exact string. On a Mac that includes the text inside screenshots.

A word that every result must have gets a + before it: "a dog running on +beach" keeps only results with "beach" in
their words (a file's or folder's name, its text, the text in a picture, what Photos knows about it, what's said) or
that show a beach by what they mean, still ranked by all the words; `+"red car"` does the same for a phrase. The `+`
counts only at the start of a word and before a letter or a quote, so "c++" and "+1 555 0100" are searched as typed,
and code search (`code:`) takes it as written. On a Mac the search field highlights the marked word where it's typed
(delete its + and it's an ordinary word again), a right-click on a word in the field offers Require, which types the
`+` for you, and a saved search keeps the words as typed, as AI apps send them in theirs.

## Private

Nothing you index leaves your computer. DigUp goes online only to download the model once and to check for updates
once a day; parakeet-mlx, if you install it, downloads its speech model once. The update check sends nothing about
your files, and you can turn it off. No account, no telemetry. The search window's map is Apple Maps: while it's
showing, Apple is sent the area in view to draw it, nothing about your files, and it never shows unless you open it.
Download Original, on a Photos result, has Photos fetch that original from your iCloud, as Photos does when you open
it. AI apps can search through DigUp only once you let them (see AI apps), and what they read goes to their AI
provider.

## Install

**Mac.** Download the DMG from [Releases](https://github.com/ARahim3/DigUp/releases/latest) and drag DigUp to
Applications, or use Homebrew: `brew install --cask arahim3/tap/digup`. It needs an Apple Silicon Mac with macOS 14 or
later.

**Windows.** Download `DigUp_x.y.z_x64-setup.exe` from the
[beta release](https://github.com/ARahim3/DigUp/releases/tag/v0.7.0-beta.2) and run it. It installs for you only, with
no admin rights. Windows may say it doesn't recognize the app, because the installer isn't signed yet: choose More
info, then Run anyway. It needs 64-bit Windows 10 or 11.

**Linux.** On Ubuntu, Debian, Mint and the like, download the .deb and install it:

```sh
sudo apt install ./DigUp_x.y.z_amd64.deb
```

The package is called `dig-up`, because Debian already has an unrelated `digup`. Anywhere else, download the
AppImage, make it executable and run it. Both are for 64-bit Intel and AMD processors and work on Ubuntu 22.04,
Debian 12, Mint 21 and newer.

Then, on any of them:

1. Open DigUp. While the model downloads (865 MB, once), pick the folders to search: whole folders, or only some of
   their subfolders. DigUp shows how long the first pass will take for each, measured on your computer.
2. Press the shortcut in any app and describe what you're looking for: **⇧⌘Space** on a Mac, **Ctrl+Shift+Space** on
   Windows and Linux.

DigUp keeps itself up to date: the Mac app, the Windows installer and the AppImage install updates with one click.
With the .deb, DigUp tells you when there's a new version and opens its release page.

## Using it

| Mac | Windows and Linux | What it does |
|---|---|---|
| ⇧⌘Space | Ctrl+Shift+Space | Opens the search panel from any app (you can change it) |
| ↓ ↑ | ↓ ↑ | Moves through the results |
| ↩ | Enter | Opens the result: PDFs at the page, recordings and videos at the moment, code in your editor at the line |
| Space | Space | A big preview, at the page or moment (once you've moved to a result, or with nothing typed) |
| ⌘↩ | Ctrl+Enter | Shows it in Finder, Explorer or your file manager |
| ⌘C | Ctrl+C (in the window) | Copies the file, to paste anywhere |
| ⌘O | Ctrl+O | The same search in a bigger window, with a picture grid and filters |
| ⌘D | | Adds it to DigUp's own Favorites, or takes it off (the ♥ under the preview) |
| ⌘S | | Saves the search window's search, with its filters, in its Saved menu |

On a Mac, Settings → Shortcuts lists every key, in the panel and the window, sets the one that opens the panel, and
shows what the search field reads besides words (`+word`, `+"a phrase"`).

On a Mac, the search window keeps All, the kinds and ♥ Favorites as chips under the field, and every other filter in
one Filters menu beside them, which says how many are on ("Filters · 2"): a library's people, albums, Photos favorites
and From (see [Apple Photos](#apple-photos)), Sensitive (see [Sensitive pictures](#sensitive-pictures)), and:

- Length, for videos and recordings: under 15 s, 15 s to 1 min, 1 to 5 min, or over 5 min
- Shape, for pictures and videos as they're shown: Portrait, Landscape, Square (sides within 5 %), Wide (2:1 or wider:
  panoramas and cinema), or an exact ratio, 16:9, 9:16, 4:3, 3:4, 3:2 or 2:3, within 2 % (16:9 is landscape, 9:16
  portrait). A phone's photo or video turned by the camera counts as it's shown, not as it's stored
- Match by, the parts of a file that may make it match, any of them: Visual (pictures, video frames, PDF pages read as
  pictures), Audio (sound, a video's soundtrack), Spoken (what's said), Text (documents, PDF text, the words in a
  picture, file and folder names) and Tags (what Photos says of an item: its labels, keywords, title, caption, people,
  albums and places). Only those parts count, by what they mean or by their words, a word that must be there (`+beach`)
  too, and why a result is there comes from one of them; each keeps the score it has without the choice. With no
  words, it lists the files that have one of them: Spoken alone, the recordings with speech

Each filter that's on is a token in the search field too (its × takes it off, as ⌫ does in an empty field); Match by
is one token, "Match: Spoken + Text". A Photos picture's size and a Photos video's length are Photos' own, so a video
that's only in iCloud has its length too; any other file's are read from the file. `digup search --length 15..60
--shape 16:9 --match-by spoken,text` does the same in the CLI (seconds, either end left out: `..15`, `300..`).

On a Mac, the search window's Saved menu (the bookmark beside the field) keeps the searches you come back to. Save This
Search… (⌘S) keeps the words, the kind and the filters (people, albums, favorites, From, the map's area, Sensitive,
Length, Shape, Match by) under a name, and choosing it searches again, so new files show up; Edit Saved Searches…
renames, reorders and deletes them. Typing the start of one's name in the panel offers it, and Tab opens it in the
window.
They're kept in `saved-searches.json` beside the index, so rebuilding the index keeps them, with Photos' people and
albums by Photos' own ids: someone renamed in Photos is still found, and someone who's gone from Photos shows struck
through, and the search keeps nothing for them rather than everyone.

DigUp lives in the menu bar on a Mac and in the tray on Windows and Linux, where you can see how indexing is going,
pause it, or open Settings. Opening it from the Start menu or your app list shows the search window.

A few things differ by system:

- On a Mac, a video opens at its moment in QuickTime Player (macOS asks once whether DigUp may control it) or IINA,
  and a PDF opens in Preview with your words in its search. On Windows and Linux, PDFs open at the page in your PDF
  viewer if it's one that can be told a page (Edge, Chrome, Firefox, Acrobat, SumatraPDF, Evince, Okular), and
  recordings and videos at the moment in VLC, mpv or MPC-HC. Other apps open the file from the start; the big
  preview plays it from the moment either way.
- On GNOME and KDE under Wayland, which don't let apps set their own shortcuts, DigUp adds Ctrl+Shift+Space to the
  desktop's keyboard settings during setup, and you change it there. On other Wayland desktops, Settings shows the
  command to give a shortcut of your own.
- On GNOME, the tray icon needs the AppIndicator extension, which Ubuntu includes. Without it, the window's ⋯ menu has
  the same items.

## What it reads

Only the folders you choose:

- pictures and screenshots (JPEG, PNG, HEIC, WebP and more), by what they show; on a Mac, screenshots by their text
  too, and an animated GIF by a few of its frames, each found at the moment it's shown
- PDFs, page by page, scans included. A long one gets its first 30 pages right away and the rest once everything
  else is in (up to 5,000 pages a file)
- documents: txt, md, rtf, docx, odt, html, and on a Mac doc, long ones the same way. Text that's mostly numbers,
  like a data export, is matched by its exact text only
- audio of any length: the model listens to 30 seconds at a time, so DigUp takes overlapping 30-second windows and a
  match points to its moment; on a Mac with parakeet-mlx, what's said in it too (see [What's said](#whats-said))
- video of any length: a frame every few seconds, one per shot, plus the soundtrack the same way as audio. A recording
  that matches in several places stays one result ("3 moments"); on a Mac the search window's preview marks every
  moment on a strip under the player and lists them ("0:42–0:51 · seen", "2:10–2:40 · heard", "0:12–0:38 · said",
  best first), and a click plays from there (Space then opens Quick Look at it)
- on a Mac with osxphotos installed, a Photos library's pictures and videos, by what they show and by what Photos knows
  about them (see [Apple Photos](#apple-photos))

Outside the folders you pick for code search, it never reads code, and inside a code project (a folder with `.git`,
`package.json` and the like) it reads only screenshots. It never reads keys, certificates, password files, hidden
folders like `.ssh`, apps or caches. It skips folders that look like datasets, and never downloads files that only
live in the cloud (iCloud on a Mac, OneDrive on Windows). You can skip more folders or file types in Settings. DigUp
only reads your files; it never changes, moves or uploads them.

The first pass happens once. On a Mac it takes a few minutes for a few hundred files and can take an hour for a big
Downloads folder. On Windows and Linux, DigUp runs the model on the graphics card where that's faster and on the
processor otherwise; on a processor alone a picture takes a few seconds (about five on a 2017 laptop's Core i5), so a
large photo library can take hours, which is why setup shows the time first. After that, a new file is searchable a
few seconds after it lands.

## Code

EmbeddingGemma 2 reads code too, so DigUp can search your projects. Code search is off until you turn it on, in
Settings → Code or during setup, for the folders you pick. Each repo shows how long reading it takes and how much room
its index needs. Then start a search with `code:` and say what the code does, or type a name that's in it:

- "code: retry a failed call with backoff" finds the function, whatever it's called
- "code: refreshAccessToken" goes to the line that defines it, not the places that call it
- "code: plot how many examples each class has" finds the notebook cell

Results open in your editor at the line: Zed, VS Code, Cursor, Sublime Text, JetBrains IDEs and a few more, Xcode on
a Mac and Notepad++ on Windows (pick one in Settings). Code has an index of its own and never shows up in other
searches. DigUp reads source files, notebooks (without their outputs) and a repo's own docs. It skips what git
ignores, vendored and generated code, data files, and anything that looks like a key or a password. While you're
working on code, the index catches up a minute after things go quiet.

On a Mac, reading code takes about 20 seconds for a small app, and about 20 minutes and 130 MB of index for all of
llama.cpp.

## Apple Photos

DigUp can search your Photos library too. Setup offers it on the folder step, with a switch and how long reading it
takes, and Settings → Photos shows each library, what's indexed of it and what Photos' last listing left out and why.
To the rest of DigUp it's a folder like any other: inside Pictures it's one of Pictures' subfolders (its switch and its
checkbox there are the same choice), and a `.photoslibrary` kept elsewhere can be chosen in Add Folders like a folder.
Its pictures are found by what they show, as everywhere else, and also by what Photos knows that no picture shows:

- "Tati at the beach" finds the photos of the person you named Tati in Photos that show a beach
- "Grandma in Lisbon", "receipt": the people and pets you've named, places from the street to the country, titles,
  captions, keywords, albums, and the labels Photos' own analysis gave each picture (what's in it, activities,
  holidays, landmarks, documents)
- "4417 receipt", "the sign that said closed for the season": the words in a picture, as Photos itself read them
  (Live Text), in screenshots and photos alike

A result opens in Photos (macOS asks once whether DigUp may control it), and Show in Photos (⌘↩) does the same. Photos
can show a picture only from the library it has open: a result from another library brings Photos forward without it.

The search window's map (its map button) shows where results were taken: Photos' place for a library's pictures, a
photo's GPS tags and a video's location for other files. Search This Area keeps the results to what's in view, and
with nothing typed it lists everything taken there, newest first. The map is Apple Maps, so it's online (see Private).

While a library is searched, the search window's Filters menu has People, Albums, Photos Favorites and From (a submenu
for each with choices): results are kept to pictures with everyone you pick in them, in any album you pick, marked ♥
in Photos, or, from From, shot on your own devices (what a device's camera saved to Photos, and older items taken with
one of those devices), saved from other apps (Messages, AirDrop, Safari…), or imported into Photos. Settings → Photos
→ My devices says which devices are yours: a device whose camera saved something is on by itself (so a new phone
joins), and you can take one off or add one that only took older pictures. Each filter that's on is a token in the
search field (its × takes it off, as ⌫ does in an empty field), and typing a person's or an album's name offers it as
a filter (Tab takes it). With nothing typed, the window lists everything the filters keep, newest first.

People also finds the people you've named in Photos in your other pictures (Downloads, the Desktop, anywhere DigUp
searches), by their faces. DigUp keeps the faces Photos named, read from Photos' own boxes, and finds the faces in each
picture outside Photos as it reads it; one close enough to someone's keeps the picture for them, and its result says
"Tati, by their face", with the face outlined in the preview. It's a guess (on a real library about 97 in 100 were right
at the level DigUp uses), and in Photos only Photos' names count. The faces are read with Vision's faceprints, which
Apple doesn't publish (DigUp looks the request up by name first, so a macOS without it gets no faces, not a crash), or,
where they're missing, with the SFace model (OpenCV Zoo, Apache-2.0) once `scripts/face-model.py convert sface` has put
it in the models folder; with neither, no faces are read. A macOS update reads them all again, on this Mac. Settings →
Photos says whether faces are on, and how many pictures outside Photos show someone you've named.

When DigUp guesses wrong, tell it: in the search window's preview, Not Tati takes a picture off her list, and clicking a
face (each one found is outlined) offers This is… with everyone named in Photos. Saying who a face is keeps it as them
however unlike it looks, and teaches DigUp, which then finds them by that face in other pictures too; saying who it
isn't sends it to whoever's next nearest, or no one. Only faces outside Photos: in Photos, name faces in Photos. What
you say is kept in `face-corrections.json` beside the index (a picture by a bookmark that follows it when it moves, a
face by where it is in the picture, a person by Photos' ids for them), so rebuilding the index keeps it.

Anything DigUp finds, in Photos or not, can be marked ♥ in DigUp itself (under the preview, or ⌘D), without touching
Photos' own favorites; the Favorites chip beside the kinds keeps those. They're kept in `favorites.json` beside the
index, so rebuilding or deleting the index keeps them; a Photos picture stays marked through downloads and edits, and
a file through moves and renames on its disk.

A result whose original is only in iCloud has Download Original under its preview: Photos gets the original from your
iCloud and keeps it in the library, as when you open it in Photos, and DigUp then reads the original under the same
result (a video by its frames and sound). Space on a video that's only in iCloud does the same once Quick Look has
stayed on it for a moment (arrowing past videos downloads none of them): Quick Look shows its stills meanwhile, with
how the download is going in their title, then plays the video. DigUp downloads nothing by itself.

DigUp reads the library through [osxphotos](https://github.com/RhetTbull/osxphotos), which needs installing once:
`uv tool install osxphotos` (or `pipx install osxphotos`). DigUp looks for it in `~/.local/bin`, Homebrew's and
MacPorts' folders and on PATH; `DIGUP_OSXPHOTOS` names another, and an empty one turns libraries off. Without it, a
library is skipped like any other bundle. macOS asks once whether DigUp may see your photos.

What it reads of a library, and what it leaves alone:

- each picture as Photos shows it: the edited version, else the original. When the original is only in iCloud
  ("Optimize Mac Storage", which can be nearly every picture), it reads Photos' own preview instead: 1,024 pixels on its
  long side for a photo, as many as DigUp gives the model anyway. A video that's only in iCloud is read from what Photos
  keeps of it on this Mac: the stills of Photos' filmstrip of it (six or so, each found like a frame of the video,
  though they carry no time; the preview shows the one that matched, the search window's preview lines them all up with
  the ones that matched marked, and Space shows them all, starting at that one, until it has downloaded the video),
  else one still of it; a video Photos keeps nothing of is left out until it's on this Mac. A picture whose file
  changes (downloaded, edited) stays one result, with all Photos says about it, and is read again.
- the words in a picture are the ones Photos read in it, kept in its catalog, so DigUp doesn't read each screenshot
  again (1.4 s each on an M3 Max on battery). On 60 iPhone screenshots read from their previews,
  Photos' reading and DigUp's found as many words, and each found over 9 in 10 of the other's codes, URLs and prices;
  each got some words the other missed, and Photos did better on the smallest previews. A screenshot Photos hasn't read
  yet is read by DigUp. DigUp unpacks Photos' reading with a Vision class Apple doesn't document
  (`VNDocumentObservation`); on a macOS without it, DigUp reads screenshots itself again.
- not what's in Recently Deleted, the shots of a burst nobody picked, shared albums, or what's Shared with You and not
  saved to the library, nor what's hidden unless Settings → Photos says to include it (`--include-hidden-photos` for
  `digup`). Live Photos are read as their photo.
- dates, cameras, file types and the broad regions Photos puts a place in ("Sun Belt") aren't among Photos' words here:
  they'd match thousands of pictures at once.
- it never changes your pictures or what Photos knows about them. osxphotos, and DigUp for the words Photos read, open
  Photos' databases read-only; SQLite still keeps its shared-memory file beside each one (the `-shm` file), as it does
  for Photos itself. osxphotos reads a database Apple doesn't document, and follows each macOS release, so after a
  macOS update you may need `uv tool upgrade osxphotos`.

A big library takes osxphotos a while to read, so its listing is kept in the index folder (`photos/`) and read again
when pictures arrive, change or download. A change that's only in Photos' database (a name given to a face, a keyword)
reaches keyword search with the next look at your folders, five minutes after the last listing at the earliest. A
library that can't be read for a while keeps what's indexed from it. A DigUp that lists more of a library than the one
before (each picture's size and each video's length, for Length and Shape) lists each library once more, by itself.
Pictures, videos and recordings outside Photos indexed before DigUp kept their sizes and lengths get them once, from
their metadata alone (milliseconds a file, and never a file that's only in iCloud).

This fork's Mac app doesn't check for updates by itself: its feed is upstream's, and an update from it would replace
the fork with upstream's release, which doesn't read Photos libraries. Check for Updates… in the menu still reads that
feed, so leave it alone unless you mean to go back to upstream.

## What's said

On a Mac with [parakeet-mlx](https://github.com/senstella/parakeet-mlx) installed, DigUp reads what's said in the
recordings in your folders, audio files and videos alike, and finds them by those words, typed exactly, and by what
they mean:

- "flight is cancelled" finds the announcement that says so, and so does "the plane trip was called off"
- the search window's preview lists each stretch that matched as a moment of what's said ("0:12–0:38 · said"), beside
  what's seen and heard, with its words under it and yours marked, and marks it on the strip; a result that matched
  there shows those words under it, yours marked, as a PDF page marks them

parakeet-mlx needs installing once, in Terminal, with the ffmpeg it uses: `uv tool install parakeet-mlx` and
`brew install ffmpeg`. DigUp looks for it as it does for osxphotos, in `~/.local/bin`, Homebrew's and MacPorts' folders
and on PATH; `DIGUP_PARAKEET` names another, and an empty one turns speech off. Without it nothing changes. Once it's
found, recordings indexed before get one more pass, by themselves: Settings → Storage → Speech says it found it and how
long that pass takes, and setup's estimate (`digup estimate`) counts the time reading what's said takes.

- parakeet-mlx runs NVIDIA's Parakeet TDT 0.6B v3 on the Mac's GPU, in a process of its own: it knows 25 European
  languages. The first time it reads anything, it downloads the model from Hugging Face (2.5 GB). On an M3 Max it read
  86 seconds of speech in under 2 seconds and 10 minutes in 10, and took 4 to 6 GB of memory while it ran.
- what's said is kept in stretches of up to about 30 seconds or 60 words, never across a silence of more than 2
  seconds; each starts at its first word, and is found by its words and by a text vector, as a document's passage is.
  Word by word timings aren't kept.
- only what's on this Mac is read: a Photos video that's only in iCloud is read for what's said once it's downloaded
  (Download Original), not from Photos' stills of it.
- when parakeet-mlx itself fails (no network for its first download, say), the recordings it failed on are read again
  later: after an hour, then twice as long each time it fails again, at most a day apart. A recording ffmpeg can't
  decode stays as it is until it changes.

## Sensitive pictures

DigUp can rate how revealing each picture is, on your Mac, with Freepik's
[nsfw_image_detector](https://huggingface.co/Freepik/nsfw_image_detector) (MIT): for each photo, screenshot, GIF frame,
video frame and still of a video in iCloud, the chance it shows something "low" (swimwear, lingerie, implied nudity),
"medium" or "high" (explicit). A picture is rated as it's read; the ones read before are rated once, in the background
under the same rules as a first pass (about an hour for 55,000 pictures; PDF pages aren't rated). A file only in iCloud
is never opened for it.

Settings → General → Blur sensitive pictures, off at first, blurs what's rated sensitive in the search window, the
panel, the preview and the moments' strips until you click it (then it shows for as long as DigUp runs; Quick Look
shows it as it is). Its positions, with what they caught on a real library of 55,000 pictures:

- Anything revealing (low or higher, 0.2 or more): nearly every nude picture, and the most ordinary pictures with them
  (about 1 in 7 pictures blurred)
- Revealing (0.5 or more): about 9 in 10 nude pictures (about 1 in 9 blurred)
- Nudity only (medium or higher, 0.5 or more): close to 9 in 10 (about 1 in 11 blurred)

The Sensitive filter in the Filters menu (and `digup search --sensitive`) keeps the pictures and videos rated sensitive
at that position, or at Revealing while blurring is off; a video counts by any of its frames. A search saved with it
keeps it, at the position blurring has when the search runs. AI apps don't see them, nor any picture not rated yet,
unless you allow it (AI apps, below). Known limits: tiny nudes inside screenshots and figures far away are missed, and
skin-toned close-ups and shirtless men are sometimes rated sensitive.

The detector isn't downloaded yet: make it once with `scripts/sensitive-model.py convert` (uv runs it; it downloads
the pinned model, converts it to Core ML in `~/Library/Application Support/DigUp/Models/sensitive/`, 330 MB, and
`scripts/sensitive-model.py check <pictures>` compares it with the original). Until it's there, Settings says so, and
pictures read meanwhile aren't rated: not blurred, not kept by the Sensitive filter, and kept from AI apps unless you
allow them. Pictures rated before keep their ratings. `digup sensitive <picture>…` rates pictures as indexing does.

## AI apps

AI apps on your Mac (Claude Code, Codex, Cursor, VS Code, Claude Desktop, or any app that starts a local MCP server)
can search your files through DigUp, if you let them. DigUp's helper speaks MCP on its input and output
(`DigUp.app/Contents/Helpers/digup mcp`), so nothing listens on the network. It's off until you turn it on in
Settings → AI apps, which also shows each of those apps' own command or config entry for it, with a Copy button.
DigUp never changes an app's settings: you run the command or add the entry yourself, and the app asks before it uses
DigUp, as you set it up there. The helper reads the index whether DigUp is open or not, and never writes to it: it
opens the index read-only, first making SQLite's log and shared-memory files beside it when they aren't there.

They get four tools, all read-only:

- `search_files`: what the search window does, with its kinds and filters (people, albums, Photos favorites, DigUp's
  favorites, From, an area on the map, a length, a shape, the parts to match by) and its required words (`+beach`); with
  no words, a kind or a filter lists what it keeps, newest first. Each result says where the file is, why it's there
  ("Matches the text on page 3"), the words that matched, and when and where it was taken.
- `read_text`: the words DigUp read from a file it returned (a document, a PDF's page, the text in a screenshot, what
  Photos knows about a picture, a stretch of code, what's said in a recording; with a `moment`, what's said within
  30 seconds of it), up to 20,000 characters.
- `get_picture`: a picture of a result, at most 768 pixels on its long side, for apps that can look at one.
- `status`: how many files are indexed, of which kinds, and whether some are still being read.

What they may see is DigUp's to say, not the app's. The helper reads Settings → AI apps at every call, so a change
applies to the very next one:

- with the switch off, every call fails: "DigUp's AI access is off. Turn it on in DigUp's Settings → AI apps."
- Photos libraries stay out until you allow them: their pictures are never returned, counted or read. Then, until you
  allow what's hidden in Photos too, an AI app sees only the pictures the library's last listing says aren't hidden:
  one it can't vouch for (indexed before hidden items were left out and not taken out yet, or listed before DigUp
  noted which are hidden) stays out until the library is listed again. People and albums are looked up only among
  what the app may see, and a picture outside Photos is someone's to it only by the faces it may see (named in Photos,
  or by you).
- code search, and pictures themselves (`get_picture`), are each off until you turn them on.
- pictures rated sensitive (at Blur sensitive pictures' position, Revealing while it's off) stay out until you allow
  them, and so does every picture or video not rated yet, read or not; `status` says how many wait to be rated.
- a file the app may not see answers as one DigUp doesn't have, so it can't tell the file is there; `mcp.log` says why.
- the tools' descriptions tell the model that whatever comes back is your data, never instructions: a file can say
  anything.

What an app reads goes to its AI provider, as anything you paste into it does. DigUp notes each call in `mcp.log` in
the index folder (which app, which tool, how many results, and why a call was refused), never what was searched for,
and Settings → AI apps shows the last 20. `get_picture` on a Photos picture reads the library's file, so macOS may ask
whether the AI app may see your photos.

The helper speaks both current MCP revisions: 2026-07-28, and 2025-11-25 (with 2025-06-18 and 2025-03-26) through
`initialize`. In a dev run with `-defaultsSuite` or another index, the command Settings shows passes them on
(`--defaults-suite`, `--index`).

## How it works

```
your folders ─► readers that turn files into pictures, text and sound
             ─► EmbeddingGemma 2 on llama.cpp, in a helper process that quits when it's done
             ─► one SQLite file: a vector for every picture, page, passage, video frame, 30 s of sound and stretch of
                what's said, plus a keyword index (code search keeps a second one, for code)
your words   ─► the same model's text part (~250 MB, only while you search) ─► nearest vectors + exact words
```

DigUp runs ggml-org's 8-bit build of EmbeddingGemma 2 through [llama.cpp](https://github.com/ggml-org/llama.cpp): on
the Mac's GPU with Metal, and on Windows and Linux on the GPU with Vulkan when a quick check at setup finds it faster
than the processor and getting the same results. Every vector lives in the same 768-dimensional space, which is why
one query can rank a video frame against a PDF page. A search embeds your words in milliseconds and compares them with
everything in the index. Exact-word matches get a boost, because no embedding holds an invoice number exactly.

The search engine is the same Swift code on every system. On a Mac it reads files with macOS's own frameworks (ImageIO,
PDFKit, AVFoundation, and Vision for the text in screenshots) and the app is SwiftUI. On Windows and Linux it reads
them with PDFium, ffmpeg, stb and miniz, and the app around it is built with [Tauri](https://tauri.app).

The index remembers which model version made its vectors. An update that leaves the vectors unchanged keeps your
index, and a test checks every llama.cpp update against stored reference vectors before it ships.

## Build from source

On a Mac you'll need Xcode 26, git, and CMake (or `uv`) for llama.cpp. If `xcode-select -p` shows the Command Line
Tools, switch to Xcode first (`sudo xcode-select -s /Applications/Xcode.app`): they lack the SwiftUI and Swift Testing
macros the build needs.

```sh
git clone https://github.com/ARahim3/DigUp && cd DigUp
scripts/build-llama.sh            # llama.cpp at a pinned tag, with a one-line patch (a few minutes)
swift build -c release && swift test
./build.sh                        # → build.noindex/DigUp.app
```

On Windows and Linux you'll need Swift 6.4, Rust and Node; on Windows also Visual Studio's C++ build tools, with the
commands run in Git for Windows' bash. `scripts/fetch-vendor.sh` and `scripts/build-llama.sh` get the libraries, then
`scripts/package-linux.sh` makes the .deb and the AppImage, and `scripts/package-windows.sh` the installer.
[The packages workflow](.github/workflows/packages.yml) has every step, down to the packages each system needs.

There's also a command-line tool, `.build/release/digup`, that indexes, searches and runs the evals from the terminal
(`digup --help`). `scripts/make-testbed.sh` builds a folder of test files to try it on on a Mac (it needs ffmpeg), and
`evals/` holds the queries ranking changes are measured with.

## FAQ

**How is this different from Spotlight or Windows Search?** They find files by their names, text and metadata. DigUp
also finds them by what they show or say, and takes you to the page or moment. They work fine side by side.

**What's different on Windows and Linux?** The search is the same: the same model, the same results. Two things are
missing for now. The text inside screenshots isn't read yet, so a screenshot is found by what it shows rather than by
an exact code typed into the search. And doc files from old Word versions, RAW photos and SVG pictures are only read
on a Mac.

**Why is the download 865 MB?** That's the model: the text part (310 MB) and the image and audio encoders (555 MB).
The app itself is about 20 MB on a Mac, and on Windows and Linux 40 to 140 MB depending on the package, since those
carry their own PDF, video and image readers.

**Will it slow my computer down?** Only the first pass is heavy. After that it reads new files only. The model runs in
a separate process that quits when it's done, and the search side only loads while you're searching.

**Which languages?** The model knows more than 100, and DigUp searches in all of them, across languages too. The evals
cover only English, Bengali and Arabic because those are the languages of the files DigUp was tested on, and Google
notes that the model isn't equally strong in every language. Two limits apply to exact words, not to meaning: the
text inside screenshots is read only on a Mac, by Apple's text recognition, which knows about 25 languages, and
languages written without spaces, like Chinese, Japanese and Thai, aren't split into words.

**How do I remove it?**
On a Mac, quit it, then delete DigUp.app and `~/Library/Application Support/DigUp`, which holds the model and the
indexes. Its settings are in `~/Library/Preferences/com.abdurrahim.DigUp.plist`. With Homebrew, `brew uninstall --cask
--zap digup` removes all of it.
On Windows, uninstall it in Settings → Apps; tick "Delete the application data" to remove the model and the index too.
On Linux, `sudo apt remove dig-up` (or delete the AppImage), then delete `~/.local/share/digup` (the model and the
index), `~/.config/com.abdurrahim.DigUp`, `~/.local/share/com.abdurrahim.DigUp` and, if it opened at login,
`~/.config/autostart/DigUp.desktop`. On GNOME, also remove its shortcut in Settings → Keyboard.

## Support

DigUp is free and open source, and it stays that way. If it helps you and you'd like to support it, you can
[buy me a coffee](https://arahim3.gumroad.com/l/support).

## Thanks

DigUp is built on [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) by Google DeepMind (Apache 2.0)
and [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT). The Mac app uses [Sparkle](https://sparkle-project.org)
(MIT) for updates. The Windows and Linux app is built with [Tauri](https://tauri.app) (MIT or Apache 2.0) and reads
files with [PDFium](https://pdfium.googlesource.com/pdfium/) (BSD), [FFmpeg](https://ffmpeg.org) (LGPL),
[stb](https://github.com/nothings/stb) (public domain) and [miniz](https://github.com/richgel999/miniz) (MIT). Their
license notices ship with the app. This fork reads Photos libraries through Rhet Turnbull's
[osxphotos](https://github.com/RhetTbull/osxphotos) (MIT), and what's said in recordings through Senstella's
[parakeet-mlx](https://github.com/senstella/parakeet-mlx) (Apache 2.0), which you install yourself. parakeet-mlx runs
[Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA, © NVIDIA Corporation, licensed
under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) and provided as is, without warranties, as converted for
MLX by mlx-community ([mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3)),
which parakeet-mlx downloads from Hugging Face; DigUp doesn't ship it.

DigUp isn't affiliated with Google, Apple or Microsoft. Gemma is a trademark of Google LLC; Mac and Spotlight are
trademarks of Apple Inc.; Windows is a trademark of Microsoft Corporation.

## License

MIT
