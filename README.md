# Jamaat Jaman RSVP — Demo

A single-page demo of an RSVP system for masjid jaman (food) planning:
ITS-based family login, a Hijri/Fatemi-first calendar built from the real
Dawoodi Bohra occasions calendar, an admin dashboard for creating jaman
events and tracking RSVP counts, and a kitchen-only view that shows nothing
but the date and the thaal count.

This is a **front-end demo only** — all data (sample families, responses,
created events) lives in browser memory and resets on every page refresh.
There is no backend, no database, and no real ITS integration. It exists to
show the committee the intended user experience before building the real
system.

## What's inside

- **Family view** — enter an ITS number (try one of the sample ones shown
  on screen), confirm the name, then RSVP per event. Edits are allowed
  until 24 hours before the event.
- **Admin view** — a Hijri-month calendar (not Gregorian) showing every
  occasion from the Fatemi calendar on its real day. Tap a date to see
  what falls on it, tick the occasion(s) a jaman is for, and create the
  RSVP event. A "+ Custom event" option covers anything not on the
  calendar. No family names are shown anywhere in this view — only
  aggregate counts.
- **Cook view** — just upcoming dates and the thaal count for each,
  already including the walk-in buffer. Nothing else.

## Running it locally

No build step is required — it's a single static HTML file.

```bash
# Option 1: just open it
open index.html        # macOS
start index.html       # Windows

# Option 2: serve it properly (recommended, avoids any file:// quirks)
npm run dev
# then visit http://localhost:3000
```

## Deploying to Vercel (recommended for sharing with the committee)

1. **Push this folder to GitHub:**
   ```bash
   git init
   git add .
   git commit -m "Jamaat jaman RSVP demo"
   git branch -M main
   git remote add origin https://github.com/<your-username>/<repo-name>.git
   git push -u origin main
   ```

2. **Import into Vercel:**
   - Go to [vercel.com/new](https://vercel.com/new)
   - Select "Import Git Repository" and pick the repo you just pushed
   - Framework preset: choose **"Other"** (it's a plain static site — no
     build command or output directory needed)
   - Click **Deploy**

3. Vercel will give you a live `https://<project>.vercel.app` URL within
   about a minute. Every push to `main` will auto-redeploy.

No environment variables, no `vercel.json` edits, and no backend setup are
needed for this demo — `vercel.json` in this repo only sets clean URLs.

### Alternative: GitHub Pages
If you'd rather not use Vercel: go to the repo's **Settings → Pages**,
set the source to the `main` branch root, and GitHub will publish
`index.html` at `https://<username>.github.io/<repo-name>/`.

## Known limitations (by design, for a demo)

- **No persistence.** Refreshing the page resets all RSVP responses,
  created events, and the change log back to the sample starting state.
  This is intentional — wiring up a real database is the next step after
  the committee signs off on the UX.
- **No real authentication.** ITS login here is a plain text match against
  a hardcoded sample list of 8 families — it is *not* secure and must not
  be used with real ITS numbers or real data.
- **1448 AH dates are derived, not transcribed.** The Hijri year 1449
  dates come directly from screenshots of the ITS app's own calendar. The
  current year (1448) was back-calculated from that data plus the known
  anchor "3 Oct 2026 = 22 Rabi al-Akhar 1448" — almost certainly correct,
  but worth a quick cross-check against the live ITS app before relying
  on it for a real event.

## Next steps for a production version

See the conversation this demo came from for the fuller discussion, but
in short: a real backend (database + API) to replace the in-memory state,
OTP or similar verification tied to the masjid's actual HOF list, an admin
login, and a yearly import of the Fatemi calendar instead of the
hand-transcribed table used here.
