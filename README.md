# huddle-leveler

Evens out loud and quiet speakers in Slack huddles on macOS 14.2+.

It uses a Core Audio process tap on every Slack process (huddle audio plays from
a `com.tinyspeck.slackmacgap.helper` process, not the main app), mutes Slack's
own output, runs the audio through a compressor, and plays the result on your
output device. When huddle-leveler stops or crashes, Slack's audio goes straight
to the device again, because the tap only mutes Slack while it exists.

## Build and run

    swift build -c release
    .build/release/huddle-leveler

Start it before or during a huddle; it waits for Slack to open audio and
re-taps when Slack's audio processes or your default output device change.
Press Enter to toggle bypass for A/B comparison, and Ctrl-C or `q` + Enter to quit.

The first run may ask for audio recording permission for your terminal
(System Settings → Privacy & Security → Screen & System Audio Recording →
System Audio Recording Only).

## Tuning

    .build/release/huddle-leveler --curve                 # show what the settings do
    .build/release/huddle-leveler --ratio 6 --makeup 18   # squash harder
    .build/release/huddle-leveler --process-file in.wav out.wav

Defaults: threshold -40 dBFS, ratio 4:1, 10 dB knee, attack 10 ms, release
300 ms, makeup +15 dB, peak ceiling -1 dBFS. A voice at -20 dBFS RMS comes out
unchanged. Louder voices are pulled down toward it and quieter ones lifted.
Below the gate (-55 dBFS) the makeup gain fades out, so silence and room noise
aren't boosted. On synthesized speech, a 15 dB gap between two voices comes out
about 7 dB apart; a 28 dB gap comes out about 12 dB apart.

## Notes

- Output goes to the system default output device. If Slack's huddle output is
  set to a different device, pass `--output <name>` (see `--list`).
- `--app <text>` or `--pid <pid>` taps something other than Slack, which is
  handy for testing (for example, `--app afplay`).
- It levels the combined huddle mix, not each person separately, so when two
  people talk over each other the louder one sets the gain.
