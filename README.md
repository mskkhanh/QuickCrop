# QuickCrop

A fast, keyboard-driven image viewer and cropper for macOS. QuickCrop views and crops WebP, GIF, JPG/JPEG and PNG images, including animated GIF and WebP, and lets you triage a folder of images by moving each one to a destination folder with a single key.

Current version: 1.6.0. Requires macOS 13 or later on Apple Silicon.

## Usage

- Choose **QuickCrop → Settings… → Choose Folder…** to set the destination folder. The setting is remembered across launches.
- While viewing an image, press **Enter** to move the file to the destination folder and open the next image in the list. In crop mode, Enter applies the crop instead.
- If a file with the same name already exists, a `(1)`, `(2)`… suffix is added so existing files in the destination are never overwritten.
- The Home screen remembers the most recently opened folder and image. **Recent Folder** opens the thumbnail grid; **Recent Image** reopens that image along with the remaining images in its folder.
- If the most recent image was moved or deleted outside the app, Recent Image picks another remaining image from the same folder.
- When no images are left, the app shows the folder with an empty thumbnail grid.

| Key | Action |
| --- | --- |
| ⌘O | Open image |
| ⌘⇧O | Open image folder |
| ⌘− / ⌘= | Smaller / larger thumbnails (size is remembered across launches) |
| ⌘G | Show thumbnails of the current folder |
| ⌘⇧H | Go to Home |
| Esc | Cancel crop; from an image go back to thumbnails; from thumbnails go back to Home |
| ← ↑ → ↓ | In thumbnails: move the selection (highlighted border) |
| Space | In thumbnails: open the selected image; while viewing: go back to thumbnails |
| Delete / ⌘Delete | Move the image to Trash (in thumbnails, the selected one) |
| C | Start cropping |
| Enter | Apply crop, or move the image to the destination folder |

## Building and testing

Requires the Xcode Command Line Tools and [libwebp](https://developers.google.com/speed/webp) at `/opt/homebrew/opt/webp` (`brew install webp`). Set `QUICKCROP_WEBP_DIR` if libwebp is installed elsewhere. Cropping WebP images uses the `cwebp` and `img2webp` tools that come with the same package.

```sh
bash build.sh          # builds build/QuickCrop-1.6.0.app
bash Tests/run.sh      # file, preference and thumbnail checks
bash Tests/viewer.sh   # Viewer integration checks
```

`build.sh` accepts an optional output path for the `.app`. The Viewer tests need a macOS session with AppKit; they use temporary images and in-memory settings.

`make_icon.swift` regenerates `QuickCrop-icon-1024.png` in the current directory.

## Source layout

| File | Contents |
| --- | --- |
| `QuickCrop.swift` | App entry point, image viewer, cropping and encoding |
| `QuickCropLibrary.swift` | Settings, moving files, Home screen and thumbnail grid |
| `WebPAnimBridge.c` / `.h` | C bridge to libwebp for decoding animated WebP |
| `Tests/` | Test programs and the scripts that build and run them |

The tests cover name conflicts, folders reached through symbolic links, preserving linked files, unreadable listings, repeated Enter presses, the last image in a folder, and cropping.
