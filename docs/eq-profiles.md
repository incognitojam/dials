# Equalizer profiles

An equalizer needs a curve, and a curve belongs to a pair of headphones rather than to
the app. Deriving one requires measuring headphones on a coupler against a target
response, which neqMac is never going to do. So the question is which existing body of
work to adopt, and what shape to store it in.

The answer is [OPRA](https://github.com/opra-project/OPRA) — Open Profiles for Revealing
Audio — a community-maintained database seeded by Roon Labs. Its schema is adopted as
neqMac's own profile format, so a profile fetched from OPRA, one bundled with the app and
one edited by hand are all the same type.

## What the database contains

Measured from the published dump on 2026-08-20:

| | count |
| --- | ---: |
| vendors | 714 |
| products | 6,230 |
| EQ profiles | 12,594 |

It is distributed as `database_v1.jsonl`, one JSON object per line, about 12 MB, with a
`type` of `vendor`, `product` or `eq`. Consumers are asked to fetch it from the mirror at
`opra.roonlabs.net` rather than from GitHub, or to host their own copy if the product is
commercial.

The code is MIT. The product and EQ data is CC BY-SA 4.0, which permits commercial use and
requires attribution in two places: a browser over the database must show the OPRA logo,
a description and a link, and any preset shown must credit its creator — more prominently
than OPRA itself. That is a constraint on the profile picker, not a licence footnote.

## The profile format

A profile is a preamp and a list of bands:

```json
{
  "author": "AutoEQ",
  "details": "Measured by Super Review",
  "type": "parametric_eq",
  "parameters": {
    "gain_db": -5,
    "bands": [
      { "type": "low_shelf", "frequency": 105,  "gain_db": -0.7, "q": 0.7 },
      { "type": "peak_dip",  "frequency": 3479, "gain_db": 6.5,  "q": 2.51 }
    ]
  }
}
```

Frequencies, gains and Q values — never coefficients. That is the same conclusion
[System audio taps](audio-taps.md) reached from the other direction: the tap's format
follows the device, the two tested devices run at 48 kHz and 44.1 kHz, and biquad
coefficients depend on the sample rate, so they have to be derived at the point the
output device or its rate changes.

Two details in the schema are worth honouring rather than reinventing.

Bands are **sorted by priority**, and software with a limited number of bands is expected
to truncate the list. A fixed ten-band equalizer is therefore not a requirement, only a
truncation policy.

The preamp is **not optional**. These are corrections dominated by cuts, and the preamp is
the headroom that keeps the sum from clipping. Across the database it runs from −18.1 dB
to +0.8 dB.

## What the corpus actually uses

This bounds the filter engine. Across all 12,594 profiles:

| Filter type | Bands |
| --- | ---: |
| `peak_dip` | 97,887 |
| `low_shelf` | 12,501 |
| `high_shelf` | 12,479 |
| `low_pass` | 5 |

RBJ peaking, low-shelf and high-shelf cover 99.995% of the corpus. The schema also allows
`high_pass`, `band_pass` and `band_stop`, and the `slope` field that the pass filters use
instead of Q, but nothing in the database exercises them.

Band counts cluster hard: 11,560 of 12,594 profiles have exactly ten bands, the rest run
from 2 to 20. Q ranges from 0.15 to 12 and centre frequencies from 8.5 Hz to 20 kHz, so
the coefficient maths has to stay stable at both ends of the audio band.

## Variants are products, not settings

OPRA models the state a headphone is worn in as part of its identity:

```
sony::wh_1000xm4                 beyerdynamic::dt_770_pro
sony::wh_1000xm4_anc_on          beyerdynamic::dt_770_pro_32_ohm
sony::wh_1000xm4_anc_off         beyerdynamic::dt_770_pro_worn_earpads
                                 beyerdynamic::dt_770_pro_dekoni_hybrid_earpads
```

This answers a question left open in [System audio taps](audio-taps.md): a published
correction targets the raw driver response, so applying one on top of a headset's own
tuning corrects twice, and a profile has to record what the headset was set to. Upstream
has already solved it by making the setting part of the product. Noise cancelling switched
on is a different product, not a modifier on one.

So an assignment stored by neqMac points at an OPRA product id, not at a headphone name.

Some headsets will say which variant they are. [Reading headset state](headset-control.md)
measures a headset reporting its own noise cancelling mode, and pushing a notification when
it changes.

## Where the data comes from

OPRA's initial ingest was [AutoEq](https://github.com/jaakkopasanen/AutoEq), which supplies
10,784 of the 12,594 profiles under the author `AutoEQ`; `oratory1990` contributes 1,342
directly. AutoEq remains the upstream measurement project and is MIT licensed, but its
`results/` tree was last refreshed in July 2025 and its README now directs users to
autoeq.app rather than to the repository.

AutoEq's text output is nonetheless the format people paste between applications:

```
Preamp: -5.1 dB
Filter 1: ON LSC Fc 105 Hz Gain -3.0 dB Q 0.70
Filter 2: ON PK Fc 6430 Hz Gain -4.2 dB Q 0.97
```

`PK`, `LSC` and `HSC` map onto `peak_dip`, `low_shelf` and `high_shelf`, so importing a
pasted block is a small parser over a format neqMac already stores. It is worth supporting
as an import path and not worth adopting as the storage format.

## Open questions

Whether to bundle the 12 MB dump or fetch it. Bundling pins a known-good snapshot and works
offline; fetching keeps the catalogue current and the binary small.

How a profile is chosen when a product has several. The DT 770 Pro carries sixteen, each
from a different measurement of the same headphone, and nothing in the data says which is
better — only who measured it.
