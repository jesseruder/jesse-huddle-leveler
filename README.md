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
    .build/release/huddle-leveler --target -20            # everyone louder overall
    .build/release/huddle-leveler --level-ratio 5         # even talkers out harder
    .build/release/huddle-leveler --soften 0              # no treble cut on loud talkers
    .build/release/huddle-leveler --process-file in.wav out.wav

Fast compression of Slack's audio is audible (it already peaks near full
scale), so by default huddle-leveler levels whole talkers with a slow gain
instead. It tracks the speech level of whoever is talking, only while someone
is talking so pauses hold the gain, following a louder talker within about
100 ms and a quieter one over about 1.5 s. Each talker moves toward -24 dBFS
RMS at 3:1 (a talker 12 dB off ends up 4 dB off), raised by up to 12 dB or
turned down by up to 15 dB.

- A boost never pushes a peak above -10 dBFS, so a loud talker starting right
  after a quiet one isn't boosted into the limiter.
- Below the gate (-55 dBFS) boosts fade out, so room noise between words
  isn't raised.
- Loud talkers get a treble cut above ~3 kHz, up to 6 dB, scaled by how far
  they're being turned down. When someone's mic clips before the audio
  reaches Slack, nothing downstream can undo that; this softens the fizz.
  The real fix is for them to lower their input level.

Fast downward compression (`--ratio`, `--threshold`, `--makeup`, `--attack`,
`--release`) is still there but off by default.

## Notes

- Output goes to the system default output device. If Slack's huddle output is
  set to a different device, pass `--output <name>` (see `--list`).
- `--app <text>` or `--pid <pid>` taps something other than Slack, which is
  handy for testing (for example, `--app afplay`).
- It levels the combined huddle mix, not each person separately, so when two
  people talk over each other the louder one sets the gain.
