import { useState, useEffect } from 'react';
import { StyleSheet, Text, View, ScrollView, ActivityIndicator, TextInput, TouchableOpacity, StatusBar } from 'react-native';
import { CameraView, useCameraPermissions } from 'expo-camera';
import AsyncStorage from '@react-native-async-storage/async-storage';

// --- Custom UI Components ---
const DstButton = ({ title, onPress, type = 'primary', disabled = false, loading = false }: { title: string, onPress: () => void, type?: 'primary'|'danger'|'warning'|'secondary', disabled?: boolean, loading?: boolean }) => {
  const bgStyles = {
    primary: { backgroundColor: '#0ea5e9', borderColor: '#0284c7' },
    danger: { backgroundColor: '#ef4444', borderColor: '#b91c1c' },
    warning: { backgroundColor: '#f59e0b', borderColor: '#d97706' },
    secondary: { backgroundColor: '#334155', borderColor: '#1e293b' }
  };
  return (
    <TouchableOpacity 
      style={[styles.button, bgStyles[type], (disabled || loading) && { opacity: 0.6 }]} 
      onPress={onPress}
      disabled={disabled || loading}
      activeOpacity={0.7}
    >
      {loading
        ? <ActivityIndicator color="#fff" />
        : <Text style={styles.buttonText}>{title}</Text>}
    </TouchableOpacity>
  );
};

// --- Vehicle Data ---
// Fetched at runtime from GET /api/catalog/vehicle-kits (the single source of
// truth shared with the desktop app). Defaults below are only fallbacks used if
// the catalog response omits the consumable template ids.
const DEFAULT_KIT_FUEL_TEMPLATE = 'FuelCanister_Large';
const DEFAULT_KIT_TORCH_TEMPLATE = 'RepairTool5';

export default function App() {
  const [permission, requestPermission] = useCameraPermissions();
  const [scanned, setScanned] = useState(false);
  const [serverInfo, setServerInfo] = useState<{ip: string, port: number, token: string} | null>(null);
  const [serverState, setServerState] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [manualMode, setManualMode] = useState(false);
  const [manualIp, setManualIp] = useState('');
  const [manualPort, setManualPort] = useState('47900');
  const [manualToken, setManualToken] = useState('');
  
  // Navigation State
  const [currentView, setCurrentView] = useState<'home'|'player_detail'|'give_item'|'give_vehicle_kit'>('home');
  
  // Broadcast State
  const [broadcastMode, setBroadcastMode] = useState(false);
  const [broadcastTitle, setBroadcastTitle] = useState('Admin Message');
  const [broadcastBody, setBroadcastBody] = useState('');
  
  // DM State
  const [dmBody, setDmBody] = useState('');

  // Tracks which async action is in-flight so its button stays pressed/disabled
  // with a spinner until the request + confirmation alert returns.
  const [busyAction, setBusyAction] = useState<string | null>(null);
  
  // Players State
  const [players, setPlayers] = useState<any[]>([]);
  const [selectedPlayer, setSelectedPlayer] = useState<any>(null);
  const [loadingPlayers, setLoadingPlayers] = useState(false);

  // Maps State
  const [maps, setMaps] = useState<any[]>([]);
  const [loadingMaps, setLoadingMaps] = useState(false);
  const [mapCooldowns, setMapCooldowns] = useState<Record<string, boolean>>({});

  // Catalog State
  const [catalog, setCatalog] = useState<any[]>([]);
  const [searchQuery, setSearchQuery] = useState('');
  const [selectedItemTemplate, setSelectedItemTemplate] = useState<any>(null);
  const [giveQty, setGiveQty] = useState('1');

  // Vehicle-kit catalog (fetched from the server — single source of truth)
  const [vehicleCatalog, setVehicleCatalog] = useState<{ fuelTemplate: string; torchTemplate: string; vehicles: any[] } | null>(null);

  useEffect(() => {
    AsyncStorage.getItem('dst_server').then(data => {
      if (data) setServerInfo(JSON.parse(data));
      setLoading(false);
    });
  }, []);

  const fetchStatus = async () => {
    if (!serverInfo) return;
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/status`, {
        headers: { 'X-Dune-Token': serverInfo.token }
      });
      const data = await res.json();
      setServerState(data);
    } catch (e) {
      setServerState(null);
    }
  };

  const fetchPlayers = async () => {
    if (!serverInfo) return;
    setLoadingPlayers(true);
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/gameplay/players`, {
        headers: { 'X-Dune-Token': serverInfo.token }
      });
      const data = await res.json();
      const online = (data.players || []).filter((p: any) => p.online_status === 'Online');
      setPlayers(online);
    } catch (e) {
      alert(`Failed to fetch players: ${e}`);
    } finally {
      setLoadingPlayers(false);
    }
  };

  const fetchMaps = async () => {
    if (!serverInfo) return;
    setLoadingMaps(true);
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/map-spinup`, {
        headers: { 'X-Dune-Token': serverInfo.token }
      });
      const data = await res.json();
      if (data.ok && data.maps) {
        setMaps(data.maps);
      }
    } catch (e) {
      alert(`Failed to fetch maps: ${e}`);
    } finally {
      setLoadingMaps(false);
    }
  };

  const fetchCatalog = async () => {
    if (!serverInfo) return;
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/catalog/items`, {
        headers: { 'X-Dune-Token': serverInfo.token }
      });
      const data = await res.json();
      if (Array.isArray(data.items)) setCatalog(data.items);
      else if (data.items) setCatalog(Object.keys(data.items).map(k => ({ templateId: k, ...data.items[k] })));
    } catch (e) {}
  };

  // Coerce a value that may be a scalar (ConvertTo-Json -Compress unwraps a
  // single-element array) back into a string array.
  const toStrArray = (x: any): string[] =>
    Array.isArray(x) ? x.map(String) : (x === null || x === undefined || x === '' ? [] : [String(x)]);

  const fetchVehicleKits = async () => {
    if (!serverInfo) return;
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/catalog/vehicle-kits`, {
        headers: { 'X-Dune-Token': serverInfo.token }
      });
      const data = await res.json();
      const rawVehicles = Array.isArray(data.vehicles) ? data.vehicles : (data.vehicles ? [data.vehicles] : []);
      setVehicleCatalog({
        fuelTemplate: data.fuelTemplate || DEFAULT_KIT_FUEL_TEMPLATE,
        torchTemplate: data.torchTemplate || DEFAULT_KIT_TORCH_TEMPLATE,
        vehicles: rawVehicles.map((v: any) => ({
          id: String(v.id ?? ''),
          label: String(v.label ?? v.id ?? ''),
          kit: toStrArray(v.kit),
          unique: toStrArray(v.unique),
          qty: (v.qty && typeof v.qty === 'object') ? v.qty : {}
        })).filter((v: any) => v.id)
      });
    } catch (e) {}
  };

  useEffect(() => {
    if (serverInfo) {
      fetchStatus();
      fetchPlayers();
      fetchMaps();
      fetchCatalog();
      fetchVehicleKits();
    }
  }, [serverInfo]);

  const handleManualPair = () => {
    if (!manualIp || !manualPort || !manualToken) {
      alert('Please fill out all fields.');
      return;
    }
    const payload = { ip: manualIp, port: parseInt(manualPort, 10), token: manualToken };
    setServerInfo(payload);
    AsyncStorage.setItem('dst_server', JSON.stringify(payload));
    alert('Paired successfully!');
  };

  const restartServer = async () => {
    if (!serverInfo) return;
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/commands/run/restart`, {
        method: 'POST',
        headers: { 'X-Dune-Token': serverInfo.token }
      });
      if (res.ok) alert('Restart command sent successfully!');
      else alert(`Failed to restart: ${await res.text()}`);
    } catch (e) { alert(`Network error: ${e}`); }
  };

  const rebootStack = async () => {
    if (!serverInfo) return;
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/commands/run/reboot`, {
        method: 'POST',
        headers: { 'X-Dune-Token': serverInfo.token }
      });
      if (res.ok) alert('Reboot command sent successfully!');
      else alert(`Failed to reboot: ${await res.text()}`);
    } catch (e) { alert(`Network error: ${e}`); }
  };

  const sendBroadcast = async (title: string, body: string, callback?: () => void, actionKey?: string) => {
    if (!serverInfo) return;
    if (!title) { alert('Title is required.'); return; }
    if (actionKey) setBusyAction(actionKey);
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/broadcasts/generic`, {
        method: 'POST',
        headers: { 'X-Dune-Token': serverInfo.token, 'Content-Type': 'application/json' },
        body: JSON.stringify({ title, body, durationSec: 30 })
      });
      if (res.ok) {
        alert('Message sent successfully!');
        if (callback) callback();
      } else {
        alert(`Failed to send message: ${await res.text()}`);
      }
    } catch (e) { alert(`Network error: ${e}`); }
    finally { if (actionKey) setBusyAction(null); }
  };

  const toggleMap = async (mapId: string, currentEnabled: boolean) => {
    if (!serverInfo || mapCooldowns[mapId]) return;
    setMapCooldowns(prev => ({ ...prev, [mapId]: true }));
    setTimeout(() => setMapCooldowns(prev => ({ ...prev, [mapId]: false })), 5000);
    const newEnabled = !currentEnabled;
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/map-spinup/${encodeURIComponent(mapId)}`, {
        method: 'POST',
        headers: { 'X-Dune-Token': serverInfo.token, 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled: newEnabled })
      });
      if (res.ok) setMaps(prev => prev.map(m => m.map === mapId ? { ...m, enabled: newEnabled } : m));
      else alert(`Failed to toggle map: ${await res.text()}`);
    } catch (e) { alert(`Network error: ${e}`); }
  };

  const runPlayerAction = async (endpoint: string, payload: any, successMsg: string, actionKey?: string) => {
    if (!serverInfo) return;
    if (actionKey) setBusyAction(actionKey);
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}${endpoint}`, {
        method: 'POST',
        headers: { 'X-Dune-Token': serverInfo.token, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      if (res.ok) alert(successMsg);
      else alert(`Failed: ${await res.text()}`);
    } catch (e) { alert(`Network error: ${e}`); }
    finally { if (actionKey) setBusyAction(null); }
  };

  // Give a single item to the selected online player via the RMQ-live path. Each
  // call is one awaited HTTP request so the server registers a separate RMQ
  // ServerCommand per item — this is the proven desktop flow. quality 0 +
  // allow_overflow makes the game deliver instantly (dropping overflow at the
  // player's feet) instead of our capacity guard rejecting a full inventory.
  const giveOneItem = async (template: string, qty: number): Promise<{ ok: boolean; error?: string }> => {
    if (!serverInfo || !selectedPlayer) return { ok: false, error: 'not connected' };
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/gameplay/players/give-item`, {
        method: 'POST',
        headers: { 'X-Dune-Token': serverInfo.token, 'Content-Type': 'application/json' },
        body: JSON.stringify({ pawn_id: selectedPlayer.id, template, qty, quality: 0, allow_overflow: true })
      });
      if (res.ok) return { ok: true };
      return { ok: false, error: await res.text() };
    } catch (e) { return { ok: false, error: String(e) }; }
  };

  const handleGiveSpecificItem = async () => {
    if (!selectedPlayer || !selectedItemTemplate) return;
    const qty = parseInt(giveQty, 10);
    if (isNaN(qty) || qty <= 0) {
      alert('Invalid quantity');
      return;
    }
    const tpl = selectedItemTemplate.templateId || selectedItemTemplate.template_id;
    setBusyAction('give-item');
    try {
      const r = await giveOneItem(tpl, qty);
      if (!r.ok) { alert(`Failed: ${r.error}`); return; }
      alert(`Gave ${qty}x ${selectedItemTemplate.name} to ${selectedPlayer.name}`);
      setCurrentView('player_detail');
      setSelectedItemTemplate(null);
      setGiveQty('1');
      setSearchQuery('');
    } finally { setBusyAction(null); }
  };

  const handleGiveVehicleKit = async (vehicle: any) => {
    if (!serverInfo || !selectedPlayer) return;
    const fuel = vehicleCatalog?.fuelTemplate || DEFAULT_KIT_FUEL_TEMPLATE;
    const torch = vehicleCatalog?.torchTemplate || DEFAULT_KIT_TORCH_TEMPLATE;
    const parts: string[] = [...vehicle.kit, ...(vehicle.unique || []), fuel, torch];
    if (parts.length === 0) {
      alert(`No kit available for ${vehicle.label}`);
      return;
    }
    // One bulk request: the server delivers each part as a spaced RMQ live give
    // (so the game finishes depositing each before the next) with drop-to-ground on.
    const items = parts.map(template => ({ template, qty: vehicle.qty?.[template] ?? 1, quality: 0 }));
    setBusyAction(`kit-${vehicle.id}`);
    try {
      const res = await fetch(`http://${serverInfo.ip}:${serverInfo.port}/api/gameplay/players/give-items`, {
        method: 'POST',
        headers: { 'X-Dune-Token': serverInfo.token, 'Content-Type': 'application/json' },
        body: JSON.stringify({ pawn_id: selectedPlayer.id, items, allow_overflow: true })
      });
      const count = vehicle.kit.length + (vehicle.unique?.length || 0);
      if (res.ok) {
        alert(`Gave ${vehicle.label} kit — ${count} parts + fuel + torch to ${selectedPlayer.name}`);
      } else {
        alert(`Failed: ${await res.text()}`);
      }
    } catch (e) { alert(`Network error: ${e}`); }
    finally { setBusyAction(null); }
    setCurrentView('player_detail');
  };

  const handleBarCodeScanned = (result: any) => {
    setScanned(true);
    try {
      const payload = JSON.parse(result.data);
      if (payload.ip && payload.port && payload.token) {
        setServerInfo(payload);
        AsyncStorage.setItem('dst_server', JSON.stringify(payload));
        alert('Paired successfully!');
      } else alert('Invalid QR Code.');
    } catch (e) { alert('Invalid QR Code format.'); }
  };

  const disconnect = () => {
    setServerInfo(null);
    setServerState(null);
    AsyncStorage.removeItem('dst_server');
  };

  if (loading) return <View style={styles.container}><ActivityIndicator size="large" color="#0ea5e9" /></View>;

  if (!serverInfo) {
    if (!permission) return <View style={styles.container}><ActivityIndicator size="large" color="#0ea5e9" /></View>;
    if (!permission.granted) {
      return (
        <View style={styles.container}>
          <StatusBar barStyle="light-content" />
          <Text style={styles.title}>Dune Server Tool</Text>
          <Text style={styles.subtitle}>Camera access is required to scan the pairing QR code.</Text>
          <DstButton onPress={requestPermission} title="Grant Permission" />
        </View>
      );
    }
    return (
      <View style={styles.container}>
        <StatusBar barStyle="light-content" />
        <Text style={styles.title}>Pair with Server</Text>
        <Text style={styles.subtitle}>Scan the pairing code from the DST Desktop app Settings tab.</Text>
        <View style={styles.alertBox}>
          <Text style={styles.alertText}><Text style={{ fontWeight: 'bold' }}>Requirement:</Text> You must have the Tailscale app installed and active on this device to connect.</Text>
        </View>
        {manualMode ? (
          <View style={styles.card}>
            <Text style={styles.cardTitle}>Manual Entry</Text>
            <TextInput style={styles.input} placeholder="Tailscale IP" placeholderTextColor="#64748b" value={manualIp} onChangeText={setManualIp} autoCapitalize="none" />
            <TextInput style={styles.input} placeholder="Port" placeholderTextColor="#64748b" value={manualPort} onChangeText={setManualPort} keyboardType="numeric" />
            <TextInput style={styles.input} placeholder="Token" placeholderTextColor="#64748b" value={manualToken} onChangeText={setManualToken} autoCapitalize="none" secureTextEntry />
            <View style={{ marginTop: 10 }}><DstButton title="Connect" onPress={handleManualPair} /></View>
            <View style={{ marginTop: 10 }}><DstButton title="Back to Scanner" type="secondary" onPress={() => setManualMode(false)} /></View>
          </View>
        ) : (
          <>
            <View style={styles.cameraContainer}>
              <CameraView style={styles.camera} facing="back" onBarcodeScanned={scanned ? undefined : handleBarCodeScanned} barcodeScannerSettings={{ barcodeTypes: ["qr"] }} />
            </View>
            {scanned && <View style={{ marginTop: 15 }}><DstButton title="Tap to Scan Again" onPress={() => setScanned(false)} /></View>}
            <View style={{ marginTop: 25 }}><DstButton title="Enter Code Manually" type="secondary" onPress={() => setManualMode(true)} /></View>
          </>
        )}
      </View>
    );
  }

  // --- RENDER ROUTER ---

  if (currentView === 'give_item') {
    const filteredCatalog = catalog.filter(i => 
      (i.name?.toLowerCase().includes(searchQuery.toLowerCase()) || 
       (i.templateId || i.template_id)?.toLowerCase().includes(searchQuery.toLowerCase())) &&
       i.name
    ).slice(0, 50);

    if (selectedItemTemplate) {
      return (
        <View style={styles.container}>
          <StatusBar barStyle="light-content" />
          <View style={styles.cardHeaderRow}>
            <Text style={styles.cardTitle}>Give: {selectedItemTemplate.name}</Text>
            <TouchableOpacity onPress={() => setSelectedItemTemplate(null)}>
              <Text style={{ color: '#0ea5e9', fontWeight: 'bold' }}>Back</Text>
            </TouchableOpacity>
          </View>
          
          <View style={styles.card}>
            <Text style={styles.infoLabel}>Template ID: <Text style={styles.infoValue}>{selectedItemTemplate.templateId || selectedItemTemplate.template_id}</Text></Text>
            <Text style={styles.infoLabel}>Category: <Text style={styles.infoValue}>{selectedItemTemplate.category || 'Unknown'}</Text></Text>
            
            <Text style={[styles.infoLabel, { marginTop: 20, marginBottom: 8 }]}>Quantity:</Text>
            <TextInput
              style={styles.input}
              value={giveQty}
              onChangeText={setGiveQty}
              keyboardType="numeric"
            />
            
            <View style={{ marginTop: 20 }}>
              <DstButton title="Send Item" type="primary" onPress={handleGiveSpecificItem} loading={busyAction === 'give-item'} />
            </View>
          </View>
        </View>
      );
    }

    return (
      <View style={styles.container}>
        <StatusBar barStyle="light-content" />
        <View style={styles.cardHeaderRow}>
          <Text style={styles.cardTitle}>Give Item</Text>
          <TouchableOpacity onPress={() => { setCurrentView('player_detail'); setSearchQuery(''); }}>
            <Text style={{ color: '#0ea5e9', fontWeight: 'bold' }}>Back</Text>
          </TouchableOpacity>
        </View>
        <TextInput
          style={styles.input}
          placeholder="Search items..."
          placeholderTextColor="#64748b"
          value={searchQuery}
          onChangeText={setSearchQuery}
          autoFocus
          autoCorrect={false}
          autoCapitalize="none"
        />
        <ScrollView style={{ flex: 1 }} keyboardShouldPersistTaps="handled">
          {filteredCatalog.map((item, idx) => (
            <TouchableOpacity key={idx} style={styles.catalogRow} onPress={() => { setSelectedItemTemplate(item); setGiveQty('1'); }}>
              <Text style={styles.playerName}>{item.name}</Text>
              <Text style={styles.playerSub}>{item.templateId || item.template_id}</Text>
            </TouchableOpacity>
          ))}
          {filteredCatalog.length === 0 && <Text style={styles.infoValue}>No items found.</Text>}
        </ScrollView>
      </View>
    );
  }

  if (currentView === 'give_vehicle_kit') {
    const kitVehicles = (vehicleCatalog?.vehicles || []).filter((v: any) => v.kit.length > 0);
    return (
      <View style={styles.container}>
        <StatusBar barStyle="light-content" />
        <View style={styles.cardHeaderRow}>
          <Text style={styles.cardTitle}>Give Vehicle Kit</Text>
          <TouchableOpacity onPress={() => setCurrentView('player_detail')}>
            <Text style={{ color: '#0ea5e9', fontWeight: 'bold' }}>Back</Text>
          </TouchableOpacity>
        </View>
        <ScrollView style={{ flex: 1 }}>
          {!vehicleCatalog ? (
            <ActivityIndicator size="small" color="#0ea5e9" style={{ marginTop: 20 }} />
          ) : kitVehicles.length === 0 ? (
            <Text style={[styles.infoValue, { marginTop: 10 }]}>No vehicle kits available.</Text>
          ) : kitVehicles.map((v: any, idx: number) => {
            const kitBusy = busyAction === `kit-${v.id}`;
            return (
              <TouchableOpacity
                key={idx}
                style={[styles.catalogRow, busyAction !== null && { opacity: 0.6 }]}
                onPress={() => handleGiveVehicleKit(v)}
                disabled={busyAction !== null}
                activeOpacity={0.7}
              >
                <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.playerName}>{v.label}</Text>
                    <Text style={styles.playerSub}>{`${v.kit.length + v.unique.length} parts + fuel + torch`}</Text>
                  </View>
                  {kitBusy && <ActivityIndicator size="small" color="#0ea5e9" />}
                </View>
              </TouchableOpacity>
            );
          })}
        </ScrollView>
      </View>
    );
  }

  if (currentView === 'player_detail' && selectedPlayer) {
    return (
      <ScrollView style={styles.container} contentContainerStyle={{ paddingBottom: 40 }} keyboardShouldPersistTaps="handled">
        <StatusBar barStyle="light-content" />
        <View style={styles.cardHeaderRow}>
          <Text style={styles.cardTitle}>Player: {selectedPlayer.name}</Text>
          <TouchableOpacity onPress={() => { setCurrentView('home'); setSelectedPlayer(null); }}>
            <Text style={{ color: '#0ea5e9', fontWeight: 'bold' }}>Back to Home</Text>
          </TouchableOpacity>
        </View>
        
        <View style={styles.card}>
          <Text style={styles.infoLabel}>Faction: <Text style={styles.infoValue}>{selectedPlayer.faction_name || 'None'}</Text></Text>
          <Text style={styles.infoLabel}>Map: <Text style={styles.infoValue}>{selectedPlayer.map || 'Unknown'}</Text></Text>
          
          <View style={{ marginTop: 20, gap: 10 }}>
            <DstButton title="Give Item..." type="primary" onPress={() => { setSearchQuery(''); setCurrentView('give_item'); }} />
            <DstButton title="Give Vehicle Kit..." type="primary" onPress={() => setCurrentView('give_vehicle_kit')} />
            <DstButton title="Fill Water" type="primary" onPress={() => runPlayerAction('/api/gameplay/players/fill-water', { pawn_id: selectedPlayer.id }, 'Filled water for ' + selectedPlayer.name, 'fill-water')} loading={busyAction === 'fill-water'} />
          </View>
        </View>

        <View style={[styles.card, { marginTop: 20 }]}>
          <Text style={styles.cardTitle}>Direct Message</Text>
          <TextInput
            style={[styles.input, { height: 80, textAlignVertical: 'top' }]}
            placeholder="Message Body"
            placeholderTextColor="#64748b"
            value={dmBody}
            onChangeText={setDmBody}
            multiline
          />
          <View style={{ marginTop: 10 }}>
            <DstButton title="Send Message" onPress={() => sendBroadcast(`To ${selectedPlayer.name}`, dmBody, () => setDmBody(''), 'dm')} loading={busyAction === 'dm'} />
          </View>
        </View>
      </ScrollView>
    );
  }

  // --- HOME VIEW ---
  const activeMaps = ['SH_HarkoVillage', 'SH_Arrakeen', 'DeepDesert_1'];
  const filteredMaps = maps.filter(m => activeMaps.includes(m.map));

  return (
    <ScrollView style={styles.container} contentContainerStyle={{ paddingBottom: 40 }} keyboardShouldPersistTaps="handled">
      <StatusBar barStyle="light-content" />
      <Text style={styles.title}>DST Dashboard</Text>
      <Text style={styles.subtitle}>Connected to {serverInfo.ip}</Text>
      
      <View style={styles.card}>
        <Text style={styles.cardTitle}>Server State</Text>
        {serverState ? (
          <>
            <View style={styles.infoRow}>
              <Text style={styles.infoLabel}>Status:</Text>
              <View style={[styles.badge, { backgroundColor: serverState.bg?.state === 'running' ? '#10b981' : '#f59e0b' }]}>
                <Text style={styles.badgeText}>{serverState.bg?.state?.toUpperCase() || 'UNKNOWN'}</Text>
              </View>
            </View>
            <View style={styles.infoRow}>
              <Text style={styles.infoLabel}>Uptime:</Text>
              <Text style={styles.infoValue}>{serverState.bg?.info?.uptime || 'N/A'}</Text>
            </View>
            <View style={styles.infoRow}>
              <Text style={styles.infoLabel}>Players:</Text>
              <Text style={styles.infoValue}>{serverState.bg?.gameServers?.[0]?.players || '0 / 0'}</Text>
            </View>
          </>
        ) : (
          <View style={[styles.alertBox, { backgroundColor: '#7f1d1d', borderColor: '#991b1b' }]}>
            <Text style={[styles.alertText, { color: '#fca5a5' }]}>
              Cannot reach server. Ensure Tailscale is installed and connected on your device.
            </Text>
          </View>
        )}
        
        <View style={{ marginTop: 20 }}>
          <DstButton title="Refresh Status" onPress={fetchStatus} />
        </View>
        <View style={{ marginTop: 15 }}>
          <DstButton title="Restart Battlegroup" type="warning" onPress={restartServer} />
        </View>
        <View style={{ marginTop: 15 }}>
          <DstButton title="Reboot Full Stack" type="danger" onPress={rebootStack} />
        </View>
      </View>

      <View style={[styles.card, { marginTop: 20 }]}>
        <View style={styles.cardHeaderRow}>
          <Text style={[styles.cardTitle, {marginBottom: 0}]}>Players Online ({players.length})</Text>
          <TouchableOpacity onPress={fetchPlayers}>
            <Text style={{ color: '#0ea5e9', fontWeight: 'bold' }}>Refresh</Text>
          </TouchableOpacity>
        </View>
        {loadingPlayers ? (
          <ActivityIndicator size="small" color="#0ea5e9" style={{marginTop: 15}} />
        ) : players.length === 0 ? (
          <Text style={[styles.infoValue, {marginTop: 10}]}>No players online.</Text>
        ) : (
          <View style={{marginTop: 10}}>
            {players.map((p, idx) => (
              <TouchableOpacity key={idx} style={styles.playerRow} onPress={() => { setSelectedPlayer(p); setCurrentView('player_detail'); }}>
                <Text style={styles.playerName}>{p.name || 'Unknown'}</Text>
                <Text style={styles.playerSub}>{p.faction_name || 'No Faction'}</Text>
              </TouchableOpacity>
            ))}
          </View>
        )}
      </View>

      <View style={[styles.card, { marginTop: 20 }]}>
        <View style={styles.cardHeaderRow}>
          <Text style={[styles.cardTitle, {marginBottom: 0}]}>Map Spin-Up</Text>
          <TouchableOpacity onPress={fetchMaps}>
            <Text style={{ color: '#0ea5e9', fontWeight: 'bold' }}>Refresh</Text>
          </TouchableOpacity>
        </View>
        {loadingMaps ? (
          <ActivityIndicator size="small" color="#0ea5e9" style={{marginTop: 15}} />
        ) : filteredMaps.length === 0 ? (
          <Text style={[styles.infoValue, {marginTop: 10}]}>Maps not available.</Text>
        ) : (
          <View style={{marginTop: 10, gap: 10}}>
            {filteredMaps.map((m, idx) => (
              <DstButton 
                key={idx} 
                title={`${m.map.replace('SH_', '')} (${m.enabled ? 'ON' : 'OFF'})`} 
                type={m.enabled ? 'primary' : 'secondary'} 
                onPress={() => toggleMap(m.map, m.enabled)} 
                disabled={mapCooldowns[m.map]}
              />
            ))}
          </View>
        )}
      </View>

      {broadcastMode ? (
        <View style={[styles.card, { marginTop: 20 }]}>
          <Text style={[styles.cardTitle, {marginBottom: 10}]}>Send Broadcast</Text>
          <TextInput style={styles.input} placeholder="Title" placeholderTextColor="#64748b" value={broadcastTitle} onChangeText={setBroadcastTitle} />
          <TextInput style={[styles.input, { height: 80, textAlignVertical: 'top' }]} placeholder="Message Body (Optional)" placeholderTextColor="#64748b" value={broadcastBody} onChangeText={setBroadcastBody} multiline />
          <View style={{ marginTop: 10 }}><DstButton title="Send to Server" type="primary" onPress={() => sendBroadcast(broadcastTitle, broadcastBody, () => setBroadcastMode(false), 'broadcast')} loading={busyAction === 'broadcast'} /></View>
          <View style={{ marginTop: 10 }}><DstButton title="Cancel" type="secondary" onPress={() => setBroadcastMode(false)} /></View>
        </View>
      ) : (
        <View style={{ marginTop: 20 }}>
          <DstButton title="Send In-Game Broadcast" type="primary" onPress={() => setBroadcastMode(true)} />
        </View>
      )}

      <View style={{ marginTop: 40, marginBottom: 40 }}>
        <DstButton title="Disconnect" type="secondary" onPress={disconnect} />
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 20, paddingTop: 60, backgroundColor: '#0f172a' },
  cameraContainer: { width: '100%', aspectRatio: 1, borderRadius: 16, overflow: 'hidden', borderWidth: 2, borderColor: '#334155', backgroundColor: '#000' },
  camera: { flex: 1 },
  title: { fontSize: 28, fontWeight: '800', textAlign: 'center', marginBottom: 6, color: '#f8fafc', letterSpacing: -0.5 },
  subtitle: { fontSize: 15, color: '#94a3b8', textAlign: 'center', marginBottom: 24 },
  card: { backgroundColor: '#1e293b', padding: 24, borderRadius: 16, borderWidth: 1, borderColor: '#334155', shadowColor: '#000', shadowOffset: { width: 0, height: 4 }, shadowOpacity: 0.3, shadowRadius: 8, elevation: 5 },
  cardHeaderRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 15 },
  cardTitle: { fontSize: 20, fontWeight: '700', color: '#f8fafc' },
  infoRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 },
  infoLabel: { fontSize: 16, color: '#cbd5e1', fontWeight: '500' },
  infoValue: { fontSize: 16, color: '#f8fafc', fontWeight: '600' },
  playerRow: { paddingVertical: 12, borderBottomWidth: 1, borderBottomColor: '#334155' },
  playerName: { fontSize: 16, color: '#f8fafc', fontWeight: 'bold' },
  playerSub: { fontSize: 13, color: '#94a3b8', marginTop: 2 },
  catalogRow: { paddingVertical: 16, borderBottomWidth: 1, borderBottomColor: '#334155', backgroundColor: '#1e293b', paddingHorizontal: 16, borderRadius: 8, marginBottom: 8 },
  badge: { paddingHorizontal: 10, paddingVertical: 4, borderRadius: 6 },
  badgeText: { color: '#fff', fontSize: 12, fontWeight: 'bold' },
  input: { borderWidth: 1, borderColor: '#334155', padding: 14, borderRadius: 8, marginBottom: 12, backgroundColor: '#0f172a', color: '#f8fafc', fontSize: 16 },
  button: { paddingVertical: 14, borderRadius: 10, alignItems: 'center', justifyContent: 'center', borderWidth: 1, shadowColor: '#000', shadowOffset: { width: 0, height: 2 }, shadowOpacity: 0.2, shadowRadius: 4, elevation: 3 },
  buttonText: { color: '#fff', fontSize: 16, fontWeight: '700', letterSpacing: 0.5 },
  alertBox: { backgroundColor: '#1e293b', padding: 16, borderRadius: 8, borderWidth: 1, borderColor: '#3b82f6', marginBottom: 20 },
  alertText: { color: '#cbd5e1', fontSize: 14, lineHeight: 20 }
});