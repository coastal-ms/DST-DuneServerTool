"""Prefer local game art; use bundled vectors when that art is unavailable."""
from pathlib import Path

FALLBACKS = {
    'game-cave.png': 'mountain.svg', 'game-lab.png': 'radar.svg',
    'game-wreck.png': 'ship.svg', 'game-encounter.png': 'ship.svg',
    'game-taxi.png': 'plane.svg', 'game-survey.png': 'flag.svg',
    'game-trade.png': 'container.svg', 'game-sietch.png': 'house.svg',
    'game-landmark.png': 'mountain.svg', 'game-intel.png': 'radar.svg',
    'game-drumsand.png': 'radar.svg', 'game-quicksand.png': 'wind.svg',
    'game-enemy.png': 'flag.svg', 'game-scrap.png': 'container.svg',
    'game-fuel.png': 'container.svg', 'live-worm.png': 'worm.svg',
    'flour-sand-v1.png': 'flour-sand.svg',
    'cargo-container.png':'container.svg',
    'vehicle-sandbike.png': 'bike.svg', 'vehicle-treadwheel.png': 'car-front.svg',
    'vehicle-buggy.png': 'car-front.svg', 'vehicle-sandcrawler.png': 'truck.svg',
    'vehicle-scout.png': 'plane.svg', 'vehicle-assault.png': 'plane.svg',
    'vehicle-carrier.png': 'plane.svg',
}
for kind in ('trainer', 'mentat', 'bene', 'swordmaster', 'planetologist', 'contact'):
    FALLBACKS['game-' + kind + '.png'] = 'flag.svg'
for kind in ('ore', 'azurite', 'bauxite', 'dolomite', 'erythrite', 'jasmium',
             'magnetite', 'stravidium', 'titanium', 'basalt', 'rhyolite'):
    FALLBACKS['game-' + kind + '.png'] = 'gem.svg'
for kind in ('plant', 'saguaro'):
    FALLBACKS['game-' + kind + '.png'] = 'flag.svg'


def icon_path(name, asset_root, bundled_root):
    # The HTTP route also validates names; keep this helper safe on its own.
    if Path(name).name != name or '/' in name or '\\' in name:
        return None
    for root, candidate in ((asset_root, name), (bundled_root, name),
                            (bundled_root, FALLBACKS.get(name))):
        if candidate:
            path = Path(root) / candidate
            if path.is_file():
                return path
    return None


def marker_icons(asset_root,bundled_root):
    """One bounded response for marker art; terrain remains a separate request."""
    import base64
    names=set(FALLBACKS) | {p.name for p in Path(bundled_root).glob('*.svg')}
    result={}
    for name in sorted(names):
        path=icon_path(name,asset_root,bundled_root)
        if path is None or path.stat().st_size>2097152:continue
        mime={'.svg':'image/svg+xml','.png':'image/png','.webp':'image/webp'}.get(path.suffix)
        if mime:result[name]='data:'+mime+';base64,'+base64.b64encode(path.read_bytes()).decode('ascii')
    return result
