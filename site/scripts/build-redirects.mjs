import fs from 'node:fs';
import path from 'node:path';
const output='redirect-dist';
fs.mkdirSync(output,{recursive:true});
for(const entry of fs.readdirSync('site/src/pages')){
 if(!entry.endsWith('.astro'))continue;
 const name=entry.slice(0,-6);
 const destination='https://duneservertool.com/'+(name==='index'||name==='404'?'':name);
 const file=name==='index'?'index.html':name==='404'?'404.html':name+'/index.html';
 fs.mkdirSync(path.dirname(path.join(output,file)),{recursive:true});
 fs.writeFileSync(path.join(output,file),`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta http-equiv="refresh" content="0;url=${destination}"><link rel="canonical" href="${destination}"><title>Dune Server Tool has moved</title></head><body><a href="${destination}">Continue to Dune Server Tool</a><script>location.replace(${JSON.stringify(destination)}+location.search+location.hash)</script></body></html>`);
}
