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

    .build/release/huddle-leveler --curve                    # show what the settings do
    .build/release/huddle-leveler --boost-below -20 --max-boost 15   # lift quiet voices more
    .build/release/huddle-leveler --ratio 4 --threshold -20  # also pull loud voices down
    .build/release/huddle-leveler --process-file in.wav out.wav

By default it only raises quiet voices; loud ones pass through untouched,
because Slack's huddle audio already peaks near full scale and pulling it down
is audible. It tracks the level of whoever is talking (only while someone is
talking, so pauses don't ramp the gain up) and moves toward a new talker over a
second or so. A talker quieter than -24 dBFS RMS is raised toward it at 3:1,
by up to 12 dB. The boost never pushes a peak above -10 dBFS, so a loud talker
starting right after a quiet one isn't boosted. Below the gate (-55 dBFS)
nothing is raised.

On synthesized speech, a talker 19 dB under a loud one comes up 5-6 dB, and the
loud one passes through unchanged.

Downward compression (`--ratio`, `--threshold`, `--makeup`, `--attack`,
`--release`) is still there but off by default.

## Notes

- Output goes to the system default output device. If Slack's huddle output is
  set to a different device, pass `--output <name>` (see `--list`).
- `--app <text>` or `--pid <pid>` taps something other than Slack, which is
  handy for testing (for example, `--app afplay`).
- It levels the combined huddle mix, not each person separately, so when two
  people talk over each other the louder one sets the gain.
