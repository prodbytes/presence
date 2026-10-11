# Test data

Real photos and clips for testing recognition on footage like the app's,
labelled by where each file sits. Committed, cleaned for a public repo:
no metadata (EXIF, GPS, camera, dates), at most 1280 px on the long side,
clips as the app records them (H.264, 30 fps, a keyframe every second, no
audio).

## Layout

```
test/data/
  labels.csv                 one row per file: path,species,subject,kind
  import.sh                  adds a folder of raw files (cleans, relabels)
  <species>/                 cats, dogs, people…
    <subject>/               who's in every file: a name (suerte), or
                             "other" for those who aren't a subject
      photos/                still pictures (.jpg)
      stills/                frames taken from a video (*_still_<n>.jpg)
      clips/                 videos (.mp4)
```

`labels.csv` paths are relative to this folder; `kind` is `photo`, `still`
or `clip`. A test reads it, not the folder names, so the layout can grow.

## What's here

| Set | Subject | Photos | Stills | Clips | Notes |
| --- | --- | ---: | ---: | ---: | --- |
| `cats/suerte` | Suerte, a black cat | 16 | 31 | 6 | stills come from the clips (`<clip>_still_<n>.jpg`) |
| `cats/other` | not Suerte | 38 | | | other cats, some black; some photos show two cats |

Added 2026-10-11 from the owner's own photos (`test.local/`, not
committed). Uses: Suerte's references from a few photos, then each other
file should be recognized as Suerte, and `cats/other` never; every file
should get the `cat` object tag; the clips go through the keyframe
sampler like the app's recordings.

## Re-running

The files are in the repo, so a fresh checkout has them. From
`presence_app/`:

- **Dart tests** read them from `test/data/…` (the working folder of
  `flutter test`), e.g. `File('test/data/labels.csv')`.
- **Chrome tests** fetch them from the fixture server
  (`python3 test/chrome/serve.py`) at `/test/data/…`.
- **On Android**, push them next to the existing fixtures:

  ```sh
  app=com.nu01.presence
  for f in $(cut -d, -f1 test/data/labels.csv | tail -n +2); do
    adb shell run-as $app mkdir -p "files/data/$(dirname "$f")"
    adb shell "run-as $app sh -c 'cat > files/data/$f'" < "test/data/$f"
  done
  ```

## Adding data

Put the raw files for one subject in a folder (anywhere; `test.local/` is
ignored by git), then:

```sh
test/data/import.sh <folder> <species> <subject>   # e.g. … cats suerte
```

It cleans and copies them into `<species>/<subject>/`, skips a `.heic`
when a `.jpg` of the same name exists, and rewrites `labels.csv` from the
whole tree. Re-running it overwrites what it made. Needs ffmpeg 7.1 or
later. Check what you add before committing: this repo is public.
