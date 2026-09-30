#ifndef LEVELER_DSP_H
#define LEVELER_DSP_H

#include <CoreAudio/CoreAudio.h>

// Compressor settings. Levels are dBFS measured as a short-term RMS of the
// louder channel, so ordinary speech sits somewhere around -35..-15 dBFS.
typedef struct {
    // Upward compression: voices quieter than boost_below_db are raised
    // toward it; louder ones are left alone.
    float boost_below_db;
    float boost_ratio;   // 3 = a voice 12 dB under the target comes out 4 dB under
    float max_boost_db;  // never raise anything by more than this
    // Downward compression, off at ratio 1.
    float threshold_db;  // compression starts here
    float ratio;         // 4 = every 4 dB over the threshold comes out as 1 dB
    float knee_db;       // width of the soft knee around the threshold
    float attack_ms;     // how fast the detector reacts to getting louder
    float release_ms;    // how fast it lets go when things get quieter
    float makeup_db;     // gain added back after compression
    float gate_db;       // below this, boost and makeup fade out so room noise isn't lifted
    float ceiling_db;    // peak limiter ceiling
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
void leveler_set_bypass(leveler_state *s, int bypass);
int leveler_get_bypass(leveler_state *s);
// Returns the meters and resets the peaks.
leveler_meters leveler_take_meters(leveler_state *s);

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
