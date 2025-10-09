# Debug Visualizer Guide

These colors are used across the Metal preview debug overlay:

- **Green wireframe** — Dynamic collider AABBs/capsules.
- **Orange circle** — Capsule foot used for ramp/tile contact.
- **Cyan dashed rectangle** — Broad-phase sweep hull (candidate query only).
- **Strong red fill** — Collider currently penetrating (>0.001 depth).
- **Light red fill** — Collider currently overlapping with negligible depth.
- **Red dot + arrow** — Contact sample (arrow points along the solver normal).
- **Yellow dot + arrow** — Contact sample with near-zero penetration depth.
- **Blue ramp wireframe** — Static ramp colliders.
- **Red rectangle wireframe** — Static tiles.
- **Purple wireframe** — Trigger volumes.
- **Orange wireframe** — Moving platforms.
- **Copy Debug Info** — Button in the Metal preview HUD copies the current snapshot (position, velocity, contacts, colliders, input state) as JSON to the clipboard for sharing.

Keep this handy so references to “cyan hull” or “orange foot” stay consistent.
