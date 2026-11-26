# Marketing screenshot flows (Maestro)

Scenario scripts for capturing marketing screenshots of nope. from the iOS
Simulator. Each flow launches the app fresh (`clearState: true`) so every
run starts from a clean, predictable slate -- no leftover data from a
previous run or from your own testing.

## One-time setup

1. Install Maestro (if you haven't already):
   ```
   curl -Ls "https://get.maestro.mobile.dev" | bash
   ```
2. Boot the Simulator and have a debug build of the app installed on it
   (`flutter run` once, or install the .app from a build). Maestro drives
   whatever build is already installed under the app id below -- it does
   not build the app itself.
3. Confirm the app id matches what's actually installed. These flows use
   `com.example.nopeApp` (from ios/Runner.xcodeproj). If you ship under a
   different bundle id, find/replace it across the files in this folder.

## Running

Run one scenario:
```
cd maestro
mkdir -p ../screenshots && cd ../screenshots
maestro test ../maestro/flows/03_home_hero.yaml
```

Run the whole marketing set in one go (recommended -- this is what you'll
re-run after any UI change):
```
cd screenshots   # or wherever you want the PNGs to land
maestro test ../maestro/flows/00_full_marketing_set.yaml
```

Screenshots are written as PNGs into whatever directory you run `maestro
test` from, named after each `takeScreenshot` step (e.g.
`03_home_hero_light.png`).

## What each flow captures

- `01_onboarding.yaml` -- intro screen (title/tagline/features/CTA) and the
  empty home state right after.
- `02_add_habit_flow.yaml` -- the "New habit" sheet mid-fill, then the
  resulting card on Home. Shows how simple setup is.
- `03_home_hero.yaml` -- the main hero shot: 4 seeded habits with strong
  streaks, in both light and dark mode. This is the one you'll want for a
  landing page above the fold.
- `04_calendar_view.yaml` -- the monthly calendar/history view.
- `05_nope_celebration.yaml` -- tapping NOPE for the day, capturing the
  confetti burst + adaptive motivational line.
- `00_full_marketing_set.yaml` -- runs all of the above back to back.

`subflows/seed_habits.yaml` is a shared helper that adds 4 demo habits
("no coffee" 47d, "doomscrolling" 63d, "junk food" 12d, "late night
snacks" 5d) -- edit the names/streak numbers there if you want different
demo data across every flow that uses it.

## Notes / things to double check

- The color and icon pickers in the "New habit" sheet aren't touched by
  these flows (every seeded habit gets the default blue "no entry" icon).
  Maestro can only target them by screen position since they're plain
  icons/swatches with no text label -- if you want varied colors/icons in
  the hero shot, open `maestro studio` (`maestro studio` while the sheet is
  open) to find exact tap coordinates and add `tapOn: point: "x%,y%"` steps
  after the streak is set.
- `takeScreenshot` fires immediately after the preceding step, so
  `05_nope_celebration` should catch the confetti mid-burst, but animation
  timing can vary slightly run to run -- if the capture looks off, add a
  `- extendedWaitUntil: {visible: "NOPE.", timeout: 500}`-style short pause
  before the screenshot, or just re-run.
- These flows assume iOS Simulator. The same YAML runs on Android too if
  you swap `appId` to `com.orbit.nope` (the Android applicationId) and
  target a booted emulator instead.
