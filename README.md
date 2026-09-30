# Huddle Leveler

Evens out loud and quiet speakers in Slack huddles on macOS 14.2+.

It taps every Slack process's audio with a Core Audio process tap (huddle
audio plays from a `com.tinyspeck.slackmacgap.helper` process, not the main
app), mutes Slack's own output, levels the audio, and plays the result on your
output device. When Huddle Leveler quits or crashes, Slack's audio goes
straight to the device again, because the tap only mutes Slack while it
exists.

It comes as a menu bar app and as a command-line tool; both run the same
engine.

## Menu bar app

    scripts/build-app.sh --install

builds `Huddle Leveler.app`, signs it with the Apple Development certificate
in your keychain (so macOS keeps its audio permission across rebuilds), and
installs it to `~/Applications`. On first launch macOS asks to let it record
system audio; allow it, or turn it on later in System Settings → Privacy &
Security → Screen & System Audio Recording → System Audio Recording Only.

The waveform icon in the menu bar opens a panel with:

- an on/off switch and the current status
- the level of whoever is talking and how much they're being turned up or down
- **Compare: hear raw Slack**, to A/B by ear (this also skips the delay)
- **Even out talkers**, **Loudness** and **Soften loud voices** sliders
- **Repair clipped peaks**
- the output device (System default follows your Mac's output)
- **Open at login**

Settings are saved between launches; **Reset to defaults** restores them.

## Command line

    swift build -c release
    .build/release/huddle-leveler

Start it before or during a huddle; it waits for Slack to open audio and
re-taps when Slack's audio processes or your output device change. Press
Enter to toggle bypass and Ctrl-C (or `q` + Enter) to quit. `--help` lists
every option. A few:

    .build/release/huddle-leveler --list                  # audio processes and output devices
    .build/release/huddle-leveler --curve                 # what the settings do to each level
    .build/release/huddle-leveler --target -20            # everyone louder overall
    .build/release/huddle-leveler --level-ratio 5         # even talkers out harder
    .build/release/huddle-leveler --process-file in.wav out.wav
    .build/release/huddle-leveler --record /tmp/huddle    # save raw + processed audio

## What it does to the audio

In order:

1. **Clipping repair.** Some mics are turned up so far that the audio hits
   full scale and flattens before it reaches Slack. Plateaus of 3 or more
   samples at full scale are redrawn as a smooth curve through the samples
   on either side (about 2 ms delay).
2. **Talker leveling.** It tracks the speech level of whoever is talking, only
   while someone is talking, so pauses hold the gain, and moves each talker
   toward -24 dBFS at 3:1: a talker 12 dB off ends up 4 dB off. It raises by
   up to 12 dB and cuts by up to 15 dB. It follows a louder talker within
   ~100 ms and a quieter one over ~1.5 s, or within ~150 ms right after a
   pause, when someone new has likely started. Boosts fade out below -55
   dBFS so room noise isn't raised, and never push a peak above -10 dBFS.
3. **Lookahead.** The leveling gain is worked out 24 ms before the audio
   plays, and a sudden loud talker is turned down at once, so they're
   already quieter when their first word comes through.
4. **Softening.** Talkers being turned down get a treble cut above ~2.5 kHz of
   up to 10 dB, which takes the edge off a clipping mic.
5. **Limiter.** A 3 ms lookahead limiter keeps peaks under -0.5 dBFS without
   flattening them.

Total delay is about 29 ms. Fast downward compression (`--ratio`,
`--threshold`, `--makeup`, `--attack`, `--release`) is available on the
command line but off by default: on Slack's already hot audio it was audible.

## Notes

- It levels the combined huddle mix, not each person separately, so when two
  people talk over each other the louder one sets the gain.
- Nothing can fully undo a clipping mic; the best fix is for that person to
  turn their input level down.
- `--app <text>` or `--pid <pid>` on the command line taps something other
  than Slack, which is handy for testing (for example, `--app afplay`).
