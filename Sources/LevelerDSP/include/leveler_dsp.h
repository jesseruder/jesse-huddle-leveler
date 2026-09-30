#ifndef LEVELER_DSP_H
#define LEVELER_DSP_H

#include <CoreAudio/CoreAudio.h>

// Compressor settings. Levels are dBFS measured as a short-term RMS of the
// louder channel, so ordinary speech sits somewhere around -35..-15 dBFS.
typedef struct {
    // Talker leveling: a slow gain moves each talker's speech level toward
    // target_db, so quiet talkers are raised and loud ones turned down.
    float target_db;
    float level_ratio;   // 3 = a talker 12 dB off target ends up 4 dB off
    float max_boost_db;  // never raise anything by more than this
    float max_cut_db;    // never turn anything down by more than this
    // Downward compression, off at ratio 1.
    float threshold_db;  // compression starts here
    float ratio;         // 4 = every 4 dB over the threshold comes out as 1 dB
    float knee_db;       // width of the soft knee around the threshold
    float attack_ms;     // how fast the detector reacts to getting louder
    float release_ms;    // how fast it lets go when things get quieter
    float makeup_db;     // gain added back after compression
    float gate_db;       // below this, boost and makeup fade out so room noise isn't lifted
    float ceiling_db;    // peak limiter ceiling
    // Treble cut above ~2.5 kHz for loud talkers, to soften the fizz of a mic
    // that clips before the audio reaches us. Scales with how far the talker
    // is being turned down: full at a cut of 5 dB or more. 0 turns it off.
    float soften_db;
    // Redraw peaks flattened at full scale by a clipping mic. Adds ~2 ms of
    // delay. 0 turns it off.
    int declip;
} leveler_params;

typedef struct leveler_state leveler_state;

// Meter readings since the last call to leveler_take_meters.
typedef struct {
    float in_peak;        // linear peak of the input
    float out_peak;       // linear peak of the output
    float level_db;       // detector level at the end of the last buffer
    float gain_db;        // gain applied at the end of the last buffer
    unsigned long long frames;  // frames processed since start
} leveler_meters;

leveler_params leveler_default_params(void);
leveler_state *leveler_create(void);
void leveler_destroy(leveler_state *s);
// Resets all state for a new stream. Keeps the bypass setting.
void leveler_init(leveler_state *s, leveler_params p, float sample_rate);
// Changes settings on a running stream without resetting its state. Safe to
// call while the audio thread is processing: the worst case is one buffer
// with a mix of old and new values.
void leveler_set_params(leveler_state *s, leveler_params p);
void leveler_set_bypass(leveler_state *s, int bypass);
int leveler_get_bypass(leveler_state *s);
// Returns the meters and resets the peaks.
leveler_meters leveler_take_meters(leveler_state *s);

// Records the next `frames` stereo frames of input and output into caller-
// owned interleaved buffers (2 * frames floats each), for diagnosis. The
// buffers must outlive the recording; leveler_init stops it.
void leveler_record(leveler_state *s, float *in_buf, float *out_buf, unsigned frames);
unsigned leveler_recorded_frames(leveler_state *s);

// Static gain (dB) the compressor applies to a signal at level_db, ignoring
// attack and release. Exposed for tests and for printing a curve.
float leveler_static_gain_db(const leveler_params *p, float level_db);

// Process frames of interleaved audio with `channels` channels (1 or 2 are
// used; any further channels are passed through). in and out may alias.
void leveler_process_interleaved(leveler_state *s, const float *in, float *out,
                                 unsigned frames, unsigned channels);

// IOProc for an aggregate device made of an output device plus a process tap.
// The tap is the aggregate's last input stream; the processed audio goes to
// the first two output channels and any other output channels are silenced.
// Registers it on `device` with `s` as its state.
OSStatus leveler_create_ioproc(AudioObjectID device, leveler_state *s, AudioDeviceIOProcID *out_proc_id);

#endif
