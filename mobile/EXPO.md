# Running the DST Mobile App via Expo (interim — before the App Store / Play release)

> **DRAFT / internal.** This is the interim distribution path for testers while the
> app is not yet on the Apple App Store / Google Play. Do **not** publish these
> steps publicly (Discord #faq, etc.) until we've actually published an Expo build
> and confirmed the flow end to end. The public-facing version belongs in #faq /
> the store listing once we go live.

The app runs inside **Expo Go**, so testers don't need a compiled binary — they
install Expo Go and open our published project.

---

## For testers (end users)

You need **one** app on your phone: **Expo Go** (runs the DST app). You do
**not** need Tailscale on the phone — the server owner runs Tailscale Funnel
on their host PC, which exposes DST to the internet on a stable public HTTPS
URL. Your phone talks to that URL directly, authenticated by a per-device
pairing token.

1. **Install Expo Go**
   - iOS: App Store → "Expo Go"
   - Android: Play Store → "Expo Go"
2. **Open the DST app in Expo Go** using the link/QR the server owner (or our
   testing channel) shares:
   - Tap the link on your phone, or
   - Open Expo Go → scan the QR we provide.
3. **Pair with the server**
   - On the host PC: DST Desktop → **Settings → Mobile App** → a QR pairing code.
   - In the DST app: **Scan** that QR. No camera? Tap **Enter Code Manually** and
     type the URL, Port, and Token shown on the Settings card.

If "Can't reach server": the host hasn't finished setting up Tailscale Funnel
(check DST Desktop → Settings → Mobile App on the host for the remote-access
status indicator), or DST isn't running on the host.

---

## For us (publishing the Expo build) — TODO before sharing the above

This is what makes the link in step 3 exist. Not done yet.

1. `eas.json` + `EXPO_TOKEN` configured (see APP_STORE.md / the EAS setup task).
2. Publish a preview/update so Expo Go can load it off-LAN, e.g.:
   ```powershell
   cd mobile
   npx eas update --branch preview --message "DST mobile test build"
   ```
3. Grab the resulting project/update URL (and/or QR) and share it in the testing
   channel. That URL is what testers open in step 3 above.
4. JS-only changes afterward: re-run `eas update` — testers get them on next open,
   no reinstall.

> When the store release lands, this whole flow is replaced by a normal App
> Store / Play install, and the #faq guide should be updated accordingly.
