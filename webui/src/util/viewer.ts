// Detect whether the DST web UI is currently being viewed from the host
// machine itself (a local WebView2 / browser tab on the same box) vs from
// a remote viewer reaching the portal over Tailscale (friend's
// DSTConsole.exe, or any other tailnet client).
//
// "Local" means window.location.hostname is loopback. Anything else —
// tailnet name, LAN IP, public hostname — is treated as remote.
//
// Used to gate access to surfaces that must NEVER be drivable from a
// remote viewer (the free-form PowerShell page, for example) while still
// letting curated remote surfaces (Commands, Gameplay Admin) render normally.
export function isLocalViewer(): boolean {
  if (typeof window === 'undefined') return true
  const host = window.location.hostname
  return host === '127.0.0.1' || host === 'localhost' || host === '::1' || host === ''
}
