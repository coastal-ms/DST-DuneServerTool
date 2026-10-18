"""Resource categories and fair selected-first refresh scheduling."""
import time, threading
def classify(name):
 pickup='_Pickup' in name
 if pickup or any(plant in name for plant in ('BurroBush','SietchStone')):return None
 for family,ore in [('Stravidium','StravidiumOre'),('Titanium','TitaniumOre'),('Azurite','AzuriteOre'),('Bauxite','BauxiteOre'),('Basalt','BasaltOre'),('Rhyolite','RhyoliteOre'),('Magnetite','MagnetiteOre'),('Dolomite','DolomiteRock'),('Erythrite','ErythriteOre')]:
  if family in name:return ore
 if 'ScrapMetal' in name or 'ScrapElectronics' in name:return 'ScrapMetalWreckage'
 if 'ImpureFuel' in name:return 'FuelCellWreckage'
 if 'Jasmium' in name:return 'JasmiumOre'
 if 'Saguaro' in name:return 'SaguaroPlant'
 if 'Primrose' in name:return 'PrimroseField'
 if 'Cistanche' in name:return 'CistanchePlant'
 return None

KINDS=('TitaniumOre', 'StravidiumOre', 'AzuriteOre', 'BauxiteOre', 'BasaltOre', 'RhyoliteOre', 'MagnetiteOre', 'DolomiteRock', 'ErythriteOre', 'JasmiumOre', 'SaguaroPlant', 'PrimroseField', 'CistanchePlant', 'ScrapMetalWreckage', 'FuelCellWreckage')
class Queue:
    def __init__(self,preferences=None,clock=time.monotonic):
        self.clock=clock;self.lock=threading.RLock();self.selected=set();self.finished={};self.retry={};self.sequence={};self.serial=0;self.region='DeepDesert';self.update(preferences or {})
    def update(self,preferences):
        with self.lock:
            self.region=preferences.get('region','DeepDesert')
            self.selected={(self.region,v.split(':')[-1]) for v in preferences.get('layers',[]) if v.startswith('poi:resource:') and v.split(':')[-1] in KINDS}
            for key in sorted(self.selected):
                if key not in self.sequence:self.sequence[key]=self.serial;self.serial+=1
    def next(self):
        with self.lock:
            now=self.clock();candidates=[]
            for region in ('DeepDesert','HaggaBasin'):
                for kind in KINDS:
                    key=(region,kind)
                    if now<self.retry.get(key,0) or key in self.finished and now-self.finished[key]<900:continue
                    # Newly selected, unscanned categories are P0. Selected
                    # refreshes follow; hidden categories rotate behind them.
                    priority=0 if key in self.selected and key not in self.finished else 1 if key in self.selected else 2
                    candidates.append(((priority,self.finished.get(key,-1),0 if region==self.region else 1,self.sequence.get(key,1000),KINDS.index(kind)),key))
            return min(candidates)[1] if candidates else None
    def reset_world(self,region):
        with self.lock:
            self.finished={k:v for k,v in self.finished.items() if k[0]!=region}
            self.retry={k:v for k,v in self.retry.items() if k[0]!=region}
    def finish(self,key,success=True):
        with self.lock:
            if success:self.finished[key]=self.clock();self.retry.pop(key,None)
            else:self.retry[key]=self.clock()+300
