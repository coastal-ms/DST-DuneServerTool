"""Read an automatic storm-cycle anchor from the current server's active log."""
from pathlib import Path
import datetime,json,re,shlex,subprocess,time
import atlas_process
UTC=datetime.timezone.utc

def parse_starts(text,region,now=None):
    now=now or datetime.datetime.now(UTC)
    lines=text.splitlines();start=next((float(line.split(' ',1)[1]) for line in lines if line.startswith('PROCESSSTART ')),None)
    if start is None:return []
    pattern=re.compile(r'^\[(\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d+)\](?:\[[^\]\r\n]{1,24}\]){1,5}LogSandStormManager: Log: Requested a Sandstorm auto-spawn on \['+re.escape(region)+r'\] Server \d+ Dimension 0$')
    stamps=[]
    for line in lines:
        match=pattern.fullmatch(line)
        if not match:continue
        try:stamp=datetime.datetime.strptime(match[1],'%Y.%m.%d-%H.%M.%S:%f').replace(tzinfo=UTC)
        except ValueError:continue
        if start-5<=stamp.timestamp()<=now.timestamp()+5:stamps.append(stamp)
    return [stamp.isoformat() for stamp in sorted(set(stamps))[-2:]]

def parse_anchor(text,region,now=None):
    stamps=parse_starts(text,region,now)
    return stamps[-1] if stamps else None

def read_anchor(memory,managers,region,run=atlas_process.run):
    if region not in ('DeepDesert','HaggaBasin'):return {}
    routes=[str(v['routeId']) for v in managers if str(v.get('routeId','0')).isdigit() and int(v['routeId'])>0]
    route=max(routes,key=int) if routes else '0';root=Path(memory.ROOT);context=memory.context
    identity=[context['pid'],str(context['startTime']),route]
    cache=root/'storm-cycle-anchor.json'
    saved={}
    try:
        saved=json.loads(cache.read_text())
        if isinstance(saved,dict) and saved.get('identity')==identity and 0<=time.time()-saved['checkedAt']<300:return saved.get('anchor',{})
    except (OSError,ValueError,KeyError,TypeError):pass
    pid=int(context['pid']);started=int(context['startTime'])
    # Only regular game log descriptors owned by this exact process are read.
    # A single bounded tail runs on cold start or a route change, never per frame.
    body=f"""btime=$(awk '$1 == "btime" {{print $2}}' /proc/stat)
        hz=$(getconf CLK_TCK)
        awk -v b="$btime" -v t="{started}" -v h="$hz" 'BEGIN {{printf "PROCESSSTART %.3f\\n",b+t/h}}'
        for fd in /proc/{pid}/fd/*; do
            file=$(readlink "$fd")
            case "$file" in */DuneSandbox/Saved/Logs/*.log*)
                tail -c 4194304 "$fd" | grep -F 'LogSandStormManager: Log: Requested a Sandstorm auto-spawn on [{region}]' | tail -20
                ;;
            esac
        done
        true
    """
    command=root/'storm-cycle-log.cmd';output=root/'storm-cycle-log.txt'
    command.write_text(f'test "$(cut -d \' \' -f22 /proc/{pid}/stat)" = "{started}" || exit 73\nsudo sh -c '+shlex.quote(body),encoding='utf-8')
    anchor={}
    if isinstance(saved,dict) and saved.get('identity',[])[:2]==identity[:2]:
        anchor=saved.get('anchor',{})
    try:
        result=run(['pwsh','-NoProfile','-File',str(root/'remote.ps1'),'-CommandFile',str(command),'-OutputFile',str(output)],capture_output=True,text=True,timeout=15)
        if result.returncode==0:
            stamps=parse_starts(output.read_text(encoding='utf-8-sig'),region)
            previous=anchor.get('recentSpawnAts',[]) or ([anchor['lastSpawnAt']] if anchor.get('lastSpawnAt') else [])
            stamps=sorted(set(previous+stamps))[-2:]
            if stamps:anchor={'lastSpawnAt':stamps[-1],'recentSpawnAts':stamps}
    except atlas_process.Cancelled:raise
    except (OSError,ValueError,subprocess.TimeoutExpired):pass
    finally:
        command.unlink(missing_ok=True);output.unlink(missing_ok=True)
    temporary=cache.with_suffix('.tmp');temporary.write_text(json.dumps({'identity':identity,'checkedAt':time.time(),'anchor':anchor}));temporary.replace(cache)
    return anchor
