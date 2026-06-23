# Backlog: Sound — pickable sound library

**Status:** backlog (filed 2026-06-22)

## Problem
The Sound settings today are six per-event on/off chime toggles (Recording
start, Rewrite start, Recording stop, Recording canceled, Transcription
complete, Error) plus a master volume. The user finds this low-value as a
prominent, always-visible Settings section — so for now Sound has been moved
under **General → Advanced** (not shown by default).

## Desired direction
Replace the per-event toggle grid with a **library of sound themes** the user
picks from:
- A small curated set of chime "packs" (e.g. Default, Subtle, Playful, Silent),
  each defining the start/stop/cancel/complete/error sounds cohesively.
- The user picks ONE theme; optional per-event overrides become advanced/rare.
- Preview ("Test") per theme.
- Possibly allow user-imported sounds later.

## Why deferred
Needs sound design + asset work (curating/licensing chime packs) and a small
data model for themes. Not release-blocking. Until then Sound lives under
General → Advanced with the existing toggles.
