# Test data

Real photos and clips, committed in
[presence_app/test/data/](../presence_app/test/data), for re-running tests on
footage like the app's instead of only public datasets. Its
[README](../presence_app/test/data/README.md) has the layout and commands.

## Layout and labels

- `<species>/<subject>/{photos,stills,clips}/`: a subject is who's in
  every file (`suerte`), or `other` for those who aren't a subject
  (strangers, other pets). Stills are frames taken from a video, named
  `<clip>_still_<n>.jpg`.
- `labels.csv`: one row per file, `path,species,subject,kind` (`kind`:
  `photo`, `still`, `clip`), paths relative to `test/data/`. Tests read
  it rather than walk the folders. It's written from the tree, never by
  hand.

## What's in it

- `cats/suerte`: Suerte, a black cat: 16 photos, 6 clips and 31 stills
  from them.
- `cats/other`: 38 photos of other cats (some black, some with two cats),
  never to be recognized as Suerte.

21 MB in all (2026-10-11).

## Adding data

`test/data/import.sh <folder> <species> <subject>` copies a folder of raw
files into `<species>/<subject>/` and rewrites `labels.csv`. Raw files stay
out of git (`test.local/`, ignored by `*.local*`). Since the repo is
public, every file is cleaned (ffmpeg 7.1+):

- all metadata dropped (EXIF, GPS, camera, dates); EXIF and video rotation
  applied to the pixels;
- at most 1280 px on the long side, the app's frame size;
- clips re-encoded as the app records them: H.264, 30 fps, a keyframe
  every second exactly (what the Android sampler reads), no audio;
- a `.heic` with a `.jpg` of the same name is skipped (the same picture);
- names without spaces or brackets (`photo (2).jpg` → `photo_2.jpg`).

Re-running overwrites what it made.

## Known limitations

- No test reads it yet; it's there for the recognition tests to come
  (Suerte's references from a few photos, the rest recognized, `other`
  never).
- One pet, one species: no people, dogs, or night (infrared) footage.
- The import script needs bash and ffmpeg 7.1 or later (older ones don't
  rotate photos by their EXIF).
