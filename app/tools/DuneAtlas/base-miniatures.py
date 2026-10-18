"""Render original schematic base miniatures from saved building transforms; no game meshes."""
from pathlib import Path
import json,math,collections,datetime,html,os
R=Path(__file__).resolve().parent

def qrotate(p,q):
 x,y,z=p;qx,qy,qz,qw=q;n=math.sqrt(sum(v*v for v in q))
 if n<.001:return p
 qx,qy,qz,qw=[v/n for v in q];tx=2*(qy*z-qz*y);ty=2*(qz*x-qx*z);tz=2*(qx*y-qy*x)
 return (x+qw*tx+qy*tz-qz*ty,y+qw*ty+qz*tx-qx*tz,z+qw*tz+qx*ty-qy*tx)

def miniature(pieces,placeables):
 faces=[];points=[];allpos=[p[4][:3] for p in pieces]+[[p['location'][k] for k in ['x','y','z']] for p in placeables];cx=sum(p[0] for p in allpos)/len(allpos);cy=sum(p[1] for p in allpos)/len(allpos);cz=min(p[2] for p in allpos)
 def project(p):return ((p[0]-p[1])*.8660254,(p[0]+p[1])*.38-p[2]*.85)
 for rec in [('piece',p) for p in pieces]+[('equipment',p) for p in placeables]:
  kind,p=rec
  if kind=='piece':name=p[3];t=p[4];pos=t[:3];q=t[3:7]
  else:
   name=p['type'];pos=[p['location'][k] for k in ['x','y','z']];qr=p['rotation'];q=[qr[k] for k in ['x','y','z','w']]
  n=name.lower();width=512;depth=512;height=32;category='floor'
  if kind=='equipment':width=150;depth=150;height=180;category='equipment'
  elif any(x in n for x in ['wall','window','doorframe','door_frame','door_']):depth=24;height=384;category='wall'
  elif 'railing' in n:depth=20;height=128;category='wall'
  elif any(x in n for x in ['column','pillar']):width=64;depth=64;height=384;category='pillar'
  elif 'foundation' in n:height=80
  elif any(x in n for x in ['ramp','stair']):height=256;category='ramp'
  elif 'roof' in n:height=40
  if 'half' in n:
   if category=='wall':height/=2
   else:width/=2
  verts=[(-width/2,-depth/2,0),(width/2,-depth/2,0),(width/2,depth/2,0),(-width/2,depth/2,0),(-width/2,-depth/2,height),(width/2,-depth/2,height),(width/2,depth/2,height),(-width/2,depth/2,height)]
  if category=='ramp':verts[4]=(-width/2,-depth/2,0);verts[7]=(-width/2,depth/2,0)
  world=[]
  for v in verts:
   a=qrotate(v,q);world.append((a[0]+pos[0]-cx,a[1]+pos[1]-cy,a[2]+pos[2]-cz))
  projected=[project(v) for v in world];points.extend(projected)
  palette=['#b9c7d0','#657d90','#899caa'] if 'sardaukar' in n else ['#d7c7a0','#8b795d','#ae9b78'] if 'harkonnen' in n else ['#b9b6a6','#616e72','#929b95']
  if kind=='equipment':palette=['#79a7b1','#345c6b','#527f8c']
  for ids,color in zip([(4,5,6,7),(1,2,6,5),(2,3,7,6)],palette):
   poly=[projected[i] for i in ids];depthkey=sum(world[i][0]+world[i][1]+world[i][2]*.7 for i in ids)/len(ids);faces.append((depthkey,poly,color))
 faces.sort(key=lambda v:v[0]);minx=min(p[0] for p in points);maxx=max(p[0] for p in points);miny=min(p[1] for p in points);maxy=max(p[1] for p in points);scale=min(440/max(1,maxx-minx),320/max(1,maxy-miny));ox=240-(minx+maxx)*scale/2;oy=180-(miny+maxy)*scale/2
 svg=['<svg xmlns="http://www.w3.org/2000/svg" width="480" height="360" viewBox="0 0 480 360"><title>Base layout</title>']
 for _,poly,color in faces:
  pts=' '.join(f'{x*scale+ox:.2f},{y*scale+oy:.2f}' for x,y in poly);svg.append(f'<polygon points="{pts}" fill="{color}" stroke="#1a272a" stroke-width="0.35" stroke-linejoin="round"/>')
 svg.append('</svg>');return ''.join(svg),{'x':(max(p[0] for p in allpos)-min(p[0] for p in allpos)+512)/100,'y':(max(p[1] for p in allpos)-min(p[1] for p in allpos)+512)/100,'height':(max(p[2] for p in allpos)-min(p[2] for p in allpos)+384)/100}

def build(source,output_root=R):
 output_root=Path(output_root);output_root.mkdir(parents=True,exist_ok=True)
 if source.get('readOnly')!='on':raise ValueError('Read-only source not confirmed')
 owners={};models={}
 for t in source['totems']:
  if t['entity']:owners[t['entity']]=t['id']
  models.setdefault(t['id'],{'id':t['id'],'name':t['name'] if t.get('name') and not t['name'].startswith('##') else 'Base '+t['id'],'map':t['map'],'location':t['location'],'claimCells':t.get('claimCells'),'pieces':[],'placeables':[]})
 for p in source['pieces']:
  if p[1] in owners:models[owners[p[1]]]['pieces'].append(p)
 for p in source['placeables']:
  if p['owner'] in owners and 'totem' not in p['type'].lower():models[owners[p['owner']]]['placeables'].append(p)
 out={};folder=output_root/'bases';folder.mkdir(exist_ok=True)
 for bid,m in models.items():
  extent=None
  if m['pieces'] or m['placeables']:
   svg,extent=miniature(m['pieces'],m['placeables']);target=folder/(bid+'.svg');tmp=target.with_suffix('.tmp');tmp.write_text(svg,encoding='utf-8');tmp.replace(target)
  types=collections.Counter(p[3] for p in m['pieces']);place=collections.Counter(p['type'] for p in m['placeables']);out[bid]={k:v for k,v in m.items() if k not in ['pieces','placeables']};out[bid].update(pieceCount=len(m['pieces']),placeableCount=len(m['placeables']),buildingCount=len(set(p[0] for p in m['pieces'])),types=types,placeableTypes=place,approximateExtentMeters=extent,schematic=True)
  data_target=folder/(bid+'.json');data_tmp=data_target.with_suffix('.json.tmp');data_tmp.write_text(json.dumps({**m,**out[bid],'observedAt':source['observedAt']}),encoding='utf-8');data_tmp.replace(data_target)
 value={'observedAt':source['observedAt'],'readOnly':True,'models':out,'geometryNote':'Saved positions and full quaternion rotations. Schematic shapes and dimensions; game meshes unavailable. Nominal foundation spacing512cm observed in234 nearest pairs; shape bounds remain approximate.'};p=output_root/'base-models-current.json';tmp=p.with_suffix('.tmp');tmp.write_text(json.dumps(value),encoding='utf-8');tmp.replace(p);return value
if __name__=='__main__':
 source=json.loads(json.loads((R/'base-models-query.json').read_text(encoding='utf-8-sig'))['rows'][0][0]);value=build(source,os.environ.get('DST_ATLAS_SNAPSHOT_ROOT',str(R)));print(json.dumps({'bases':len(value['models']),'pieces':sum(m['pieceCount'] for m in value['models'].values()),'readOnly':value['readOnly']}))
