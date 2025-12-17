# Gravitas Album (in-place fork)

This `Album/` folder adds a new **Gravitas Album** app target alongside the existing **Gravitas Threads** app.

**Goal**
- Reuse the Threads 3D sphere simulation + interaction model (selection, absorb loop, thumbs tuning, history/scenes).
- Swap the backend from network posts to the user’s **Photos / iCloud Photos** library assets.

**What’s intentionally omitted (v0)**
- Any network-feed backend logic (endpoints/decoding/UI) or web affordances.
- Reader/Dream agent frameworks or document pipelines.
- Printing/commerce/cloud upload features.

**Build**
- Open `GravitasThreads/GravitasThreads.xcodeproj`
- Select scheme/target `GravitasAlbum`
- Run on device/simulator

**Notes**
- Photos access requires user permission; this target sets `NSPhotoLibraryUsageDescription` via build settings (no Info.plist edits in the Threads target).
- The curved canvas is isolated as a Swift package at `Album/CurvedLayout/CurvedLayoutKit`.
