# Troubleshooting P34 / "Connection Request Timed Out"

P34 (the in‑game **"Connection Request Timed Out"** error) means a player's
client found your server but couldn't complete the connection. The server can
look perfectly healthy in DST and still hand out P34, because the failure is
almost always in the **network path between the player and your server**, not in
the game server itself.

This guide is the consolidated, source‑of‑truth version of everything we've
learned helping self‑hosters through the P34 wave. Work through it top to bottom.

---

## Step 0 — Run the built‑in check first

**Settings → Public IP / DDNS → Connection check (P34 / can't join).**

It reads, straight from the battlegroup config, the address your server
**advertises** to every client, and compares it against your real public IP and
your K3s ExternalIP. It works even when the servers are down or the game DB is
empty. What it shows decides which section below applies:

- **Red / flags a problem →** Section A.
- **Green, but players still get P34 →** Section B.
- **Server was listed and has now dropped off the browser →** Section C.

---

## Section A — The check is RED (wrong advertised address)

### A1. "Advertising a private address" (private‑datacenter setup)

**Cause:** choosing **Private** instead of **External** during VM setup pins a
private/LAN address (often `127.0.0.1`) into the server's
`HOST_DATACENTER_IP_ADDRESS`. The director re‑advertises that address to every
client on each boot — so players on your **own** network connect, but anyone
outside times out into P34.

**Fix:** click **Fix it automatically** in the connection check. It rewrites the
advertised address to your public IP and restarts the battlegroup. (Requires
DST **v12.13.13+**.)

### A2. Stale or changed public IP

**Cause:** your public IP changed (most home connections are dynamic) and the
server is still advertising the old one.

**Fix:** **Settings → Public IP / DDNS → Apply** your current public IP (or use
**Fix it automatically**). If your IP changes often, set a **DDNS hostname** in
the same card so DST can re‑resolve it. Re‑applying the *same* IP is also a valid
repair and is supported (v12.13.13+).

---

## Section B — The check is GREEN but players still get P34

Green means the address your server advertises is correct **and reachable**. So
the advertised‑address layer is fine — the problem is in forwarding, the test
path, or IPv6.

### B1. Forward the **full** UDP port range

Each map uses its **own** UDP port (Overmap 7777, Survival_1 7778,
DeepDesert_1 7779, and on‑demand maps land elsewhere in the range). On your
router, forward the whole range to the **VM's LAN IP**:

- **UDP 7777–7810** (game)
- **TCP 31982** (login / RabbitMQ)

Forwarding only 7777 lets players reach one map but P34 on every other. Reserve
the VM's LAN IP in your router (DHCP reservation) so the forward target can't
drift.

### B2. You're testing from your **own** network (NAT loopback / hairpin)

Joining your server by its **public IP** from a device on the **same network**
exercises your router's NAT loopback (hairpin), **not** the real outside path.
Many routers (Asus and TP‑Link mesh among them) handle UDP hairpin poorly, so it
P34s for you while outside players connect fine.

- **Always have someone *outside* your network test first** before assuming the
  server is broken.
- **To play from inside the house on another PC:** add a one‑time route on that
  **gaming PC** (Command Prompt as Administrator) so its traffic to the public IP
  goes straight to the server over the LAN:

  ```
  route -p add <PUBLIC_IP> mask 255.255.255.255 <VM_LAN_IP>
  ```

  Example: `route -p add 67.55.18.153 mask 255.255.255.255 192.168.68.62`.
  `-p` makes it survive reboots; undo with `route delete <PUBLIC_IP>`. This works
  because the server VM already answers on its public IP. A **console**
  (PlayStation/Xbox) can't take a local route — it must connect by the server's
  **LAN IP**, or the router needs NAT‑loopback support.

### B3. IPv6 on the server's network adapter

Several hosts fixed "green but still P34" by **disabling IPv6 on the server's
NIC** (the LAN adapter on the host, not the router), **rebooting**, then
**re‑applying the public IP** in DST. Theory: with IPv6 on, the server can
advertise or route over an IPv6 path clients can't reach, while your IPv4
forwarding works — so the IPv4 check passes but joins time out. This is one of
the most common fixes for the "green but P34" case.

### B4. Double‑NAT or CGNAT (an ISP box in front of your router)

If outside players still can't connect and forwarding looks right, check whether
a second router/modem sits in front of yours. In your router's admin, read its
**WAN / Internet IP** and compare to <https://whatismyip.com> on the server PC:

- **WAN IP is private** (`192.168.x`, `10.x`, `172.16–31.x`) → **double‑NAT**:
  the ISP box is also routing. Put the ISP modem in **bridge / pass‑through**
  mode so your router gets the public IP, or add the same UDP 7777–7810 + TCP
  31982 forward on the ISP modem pointing at your router's WAN IP.
- **WAN IP is `100.64`–`100.127`** → **CGNAT**: your ISP gives you no real public
  IP, so port forwarding can't work at all. You'd need a public IP from your ISP
  (often a free request or a small fee) or a UDP‑capable relay/VPS. (DST's
  Tailscale Funnel only exposes the **admin dashboard** to your phone — it does
  **not** route game traffic.)

---

## Section C — The server dropped off the browser (can't register)

**Symptom:** your server was listed and joinable, then disappeared from the
in‑game browser — often after a restart — yet the connection check still shows
**green** and everything looks healthy.

**Cause:** the server can't reach Funcom's matchmaker to register itself, usually
because the VM lost its **default route** (no working internet path out). On
DST builds **before v12.13.14**, running **Fix it automatically** could, on some
setups, write a **wrong default gateway** into the VM's network config. It keeps
working until the next full restart — then outbound dies and the server silently
delists.

**Fix:**

1. **Update to DST v12.13.14 or later** and re‑run **Fix it automatically** — it
   now recovers your network's real gateway automatically and repairs the route.
2. **Manual recovery** (if you want it back immediately, on the VM shell — replace
   `<REAL_GATEWAY>` with your router's LAN IP, e.g. `192.168.1.1` or
   `192.168.1.254`):

   ```
   sudo ip route del default
   sudo ip route add default via <REAL_GATEWAY> dev eth0
   ping -c 2 8.8.8.8
   ```

   If the pings succeed, the server re‑registers within a few minutes. Make it
   permanent so a reboot can't undo it by setting `gateway <REAL_GATEWAY>` in
   `/etc/network/interfaces`.

You can spot this case in a diagnostics bundle: the game‑server logs show
`matchmaker request failed: [Errno 101] Network unreachable`.

---

## Section D — Part of the P34 wave is Funcom‑side

Since Funcom's **1.4.10.0** patch, some servers P34 after a restart while a fresh
vanilla server connects normally. That portion is a Funcom‑side issue and needs
their fix — the steps above resolve the **host‑side** causes, which are the
majority of cases we've seen.

---

## Still stuck? Send logs

In DST: **Help → Create GitHub Issue** (it also saves a diagnostics bundle), or
grab the diagnostics zip and attach it. The game‑server logs and pod status let
us read exactly what your server is reporting to Funcom — which beats guessing.
Capture the bundle **while the battlegroup is running**, or it can't collect the
live logs.

---

### Quick reference

| What you see | Likely cause | Section |
| --- | --- | --- |
| Check red: "advertising a private address" | Private‑datacenter setup (127.0.0.1) | A1 |
| Check red: wrong public IP | Stale/changed public IP | A2 |
| Green, one map works others P34 | Only port 7777 forwarded | B1 |
| Green, only *you* (same network) can't join | NAT loopback / hairpin | B2 |
| Green, nobody outside can join | IPv6, or incomplete forwarding | B1 / B3 |
| Green, outside still fails, WAN IP is private/100.64 | Double‑NAT / CGNAT | B4 |
| Was listed, now gone, check still green | Lost default route (gateway) | C |
| Fresh vanilla server joins, yours P34 after restart | Funcom‑side | D |
