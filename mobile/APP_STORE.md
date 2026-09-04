# Native App Sunset

The iOS and Android companion apps are in a short retirement transition. Keep
the existing builds functional for several DST releases, publish one final
notice-bearing build if needed, and direct every user to the responsive Browser
Portal over Tailscale. Do not add native-only features during this period.

Remove this directory only after the announced transition has elapsed and the
Browser Portal replacement has been field-verified.

## App Store Description Guidelines

When publishing the **Dune Server Tool (DST)** mobile app to the Apple App Store
or Google Play Store, make it clear that connecting requires the **server
owner** to have Tailscale Funnel enabled on the host PC — but that the **phone
itself needs nothing beyond this app**. This prevents bad reviews from users
who install Tailscale on their phone thinking it's required (it isn't) and
from users trying to connect to a host that hasn't set up remote access yet.

### Suggested App Store Description Snippet:

```text
Dune Server Tool (DST) Mobile Companion

Manage and monitor your private Dune: Awakening server right from your phone.
View server status, manage players, and perform admin actions on the go.

SUNSET NOTICE
The native companion app is being retired after a short transition. Existing
users can continue using it temporarily, but should move now to DST's full
Browser Portal in Safari or Chrome. Open DST Desktop, then use Settings >
Remote Device Access to get the Tailscale link or QR code.

⚠️ REQUIREMENTS (server-side only)
To connect, the DST server owner must have set up Tailscale Funnel on the host
PC running DST. This gives their DST a stable public HTTPS address that your
phone can reach securely without exposing the server to the wider internet.

You do NOT need to install Tailscale on your phone. You do NOT need to be on
the server owner's Tailscale network. Just install this app, then scan the
pairing QR code shown in DST Desktop → Settings → Mobile App. The QR encodes
the host's Funnel URL and a per-device token that authenticates you.

If you can't connect, the host almost certainly hasn't finished the Tailscale
Funnel setup yet — ask them to check DST Desktop → Settings → Mobile App for
the "Remote access ready" indicator.
```
