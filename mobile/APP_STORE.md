# App Store Description Guidelines

When publishing the **Dune Server Tool (DST)** mobile app to the Apple App Store or Google Play Store, make sure to include explicit instructions about the Tailscale requirement so users don't leave bad reviews when they can't connect.

### Suggested App Store Description Snippet:

```text
Dune Server Tool (DST) Mobile Companion

Manage and monitor your private Dune: Awakening server right from your phone. View server status, manage players, and perform admin actions on the go.

⚠️ IMPORTANT REQUIREMENTS ⚠️
To securely connect to your server without exposing it to the public internet, this app REQUIRES Tailscale.

Before you can connect:
1. You must have the Tailscale VPN app installed and active on your mobile device.
2. The DST Desktop server owner must have Tailscale running on the server PC.
3. The server owner must add your Tailscale account to their network (Tailnet).

Once connected to Tailscale, simply scan the pairing QR code from the DST Desktop app Settings tab to link your phone.
```
