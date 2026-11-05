# Sounds shipped in the app

## `Resources/Sounds/radio-squelch.caf`

The opening squelch («كشش») of the «أصوات اللاسلكي» start cues (sender press and
incoming transmission). Used in `Sources/PTT/PTTRadioSounds.swift`.

- **Source:** Pixabay, uploader `freesound_community`, "walkie-talkie" (Pixabay file id 83500;
  downloaded as `freesound_community-088524_walkie-talkie-83500.mp3`). Found through the Pixabay
  search page https://pixabay.com/sound-effects/search/walkie%20talkie%20beep/ (item 83500).
- **Licence:** Pixabay Content License, https://pixabay.com/service/license-summary/. Free for
  commercial use. No attribution required.
- **Changes:** none to the sound itself. It was only trimmed and levelled: the leading encoder
  delay (≈ 13 ms) and the trailing silence were cut, leaving the first ≈ 160 ms; a 1 ms fade-in and
  12 ms fade-out were added; the peak was set to −9 dBFS; and it was converted to 16 kHz mono 16-bit
  CAF, the walkie-talkie's own format. The source mp3 is not in the repository or the app bundle.

## Everything else

The chirps, the roger beep and the squelch tails (and the fallback squelch used if the file
cannot be loaded) are synthesised at run time by `PTTRadioSynth`. They are original and not
sampled from any product.
