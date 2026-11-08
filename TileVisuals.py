#!/usr/bin/env python3
"""Live Music metadata and cached artist portraits for the video layer only."""
from pathlib import Path
import concurrent.futures
import hashlib
import html
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.parse
import urllib.request

HERE=Path(__file__).resolve().parent
STOP=threading.Event()
API_LOCK=threading.Lock()
CACHE_LOCK=threading.Lock()
LAST_API_CALL=0.0

def fetch(url, limit=12_000_000):
    if not url.startswith('https://'):
        raise ValueError('Artwork URLs must be HTTPS')
    request=urllib.request.Request(url,headers={'User-Agent':'SurroundStream/0.4 (personal now-playing display)'})
    with urllib.request.urlopen(request,timeout=10) as response:
        data=response.read(limit+1)
    if len(data)>limit:raise ValueError('Artwork response too large')
    return data

def normalized(text):
    return ''.join(c for c in unicodedata.normalize('NFKD',text).casefold() if c.isalnum())

def artist_name(info):
    artist=info.get('albumArtist') or info.get('artist','')
    if normalized(artist) in ('variousartists','originalsoundtrack'):
        artist=info.get('artist','')
    return artist.split(' & ')[0].strip()

def prune_cache(cache):
    # Local artwork is disposable; keep disk use bounded across long sessions.
    with CACHE_LOCK:
        files=sorted(cache.glob('*.jpg'),key=lambda p:p.stat().st_mtime,reverse=True)
        size=0
        for i,path in enumerate(files):
            size+=path.stat().st_size
            if i>=192 or size>320_000_000:path.unlink(missing_ok=True)
        for path in sorted(cache.glob('gallery-*.json'),key=lambda p:p.stat().st_mtime,reverse=True)[48:]:
            path.unlink(missing_ok=True)

def gallery(info, cache):
    """Official community API; exact artist matches, cached locally for a week."""
    global LAST_API_CALL
    artist=artist_name(info)
    target=cache/('gallery-'+hashlib.sha256(artist.encode()).hexdigest()[:24]+'.json')
    if target.exists() and time.time()-target.stat().st_mtime<7*86400:
        value=json.loads(target.read_text())
        if all(Path(p).exists() for p in value['paths']):return value
    with API_LOCK:
        if STOP.wait(max(0,2.1-(time.monotonic()-LAST_API_CALL))):return {'paths':[]}
        LAST_API_CALL=time.monotonic()
    url='https://www.theaudiodb.com/api/v1/json/123/search.php?'+urllib.parse.urlencode({'s':artist})
    rows=json.loads(fetch(url)).get('artists') or []
    matches=[r for r in rows if normalized(r.get('strArtist',''))==normalized(artist)]
    if not matches:raise RuntimeError('No exact artist gallery match')
    row=matches[0];paths=[]
    for field in ['strArtistFanart','strArtistFanart2','strArtistFanart3','strArtistThumb']:
        image_url=row.get(field) or ''
        if not image_url or not (urllib.parse.urlsplit(image_url).hostname or '').endswith('.theaudiodb.com'):continue
        image=cache/(hashlib.sha256(image_url.encode()).hexdigest()[:24]+'.jpg')
        if not image.exists():
            temporary=image.with_suffix('.tmp');temporary.write_bytes(fetch(image_url));temporary.replace(image)
        image.touch();paths.append(str(image))
        if STOP.is_set():break
    value={'paths':list(dict.fromkeys(paths)),'credit':'Photos · TheAudioDB',
           'source':'https://www.theaudiodb.com/artist/'+str(row.get('idArtist',''))}
    target.write_text(json.dumps(value));prune_cache(cache)
    return value

def portrait(info, cache):
    artist=artist_name(info)
    key=hashlib.sha256(artist.encode()).hexdigest()[:24]
    target=cache/(key+'.jpg')
    if target.exists():
        target.touch();return str(target),'Apple Music'
    query=urllib.parse.urlencode({'term':artist,'entity':'musicArtist','country':'in','limit':5})
    results=json.loads(fetch('https://itunes.apple.com/search?'+query))['results']
    matches=[r for r in results if normalized(r.get('artistName',''))==normalized(artist)]
    if not matches:raise RuntimeError('No unambiguous artist match')
    page_url=matches[0]['artistLinkUrl'].split('?')[0]
    if urllib.parse.urlsplit(page_url).hostname!='music.apple.com':raise ValueError('Unexpected artist host')
    page=fetch(page_url).decode()
    match=re.search(r'"artwork":\{"dictionary":\{[^{}]{0,1800}"url":"([^"\n]+)"',page)
    if match:
        url=json.loads('"'+match[1]+'"').replace('{w}','1600').replace('{h}','1600').replace('{c}','bb').replace('{f}','jpg')
    else:
        match=re.search(r'<meta property="og:image" content="([^"]+)"',page)
        if not match:raise RuntimeError('No artist portrait found')
        url=re.sub(r'/\d+x\d+[^/]*\.(?:png|jpg)(?:\?.*)?$','/1600x1600bb.jpg',html.unescape(match[1]))
    host=urllib.parse.urlsplit(url).hostname or ''
    if not host.endswith('.mzstatic.com'):raise ValueError('Unexpected portrait host')
    raw=fetch(url)
    temporary=target.with_suffix('.tmp');temporary.write_bytes(raw);temporary.replace(target)
    prune_cache(cache)
    return str(target),'Apple Music'

def album_cover(info, cache):
    query=urllib.parse.urlencode({'term':info.get('name','')+' '+info.get('artist',''), 'entity':'song','country':'in','limit':5})
    results=json.loads(fetch('https://itunes.apple.com/search?'+query))['results']
    matches=[r for r in results if normalized(r.get('trackName',''))==normalized(info.get('name',''))
             and normalized(r.get('artistName',''))==normalized(info.get('artist',''))]
    if not matches:raise RuntimeError('No matching album artwork')
    url=matches[0].get('artworkUrl100','').replace('100x100','1000x1000')
    if not (urllib.parse.urlsplit(url).hostname or '').endswith('.mzstatic.com'):raise ValueError('Unexpected artwork host')
    target=cache/(hashlib.sha256(url.encode()).hexdigest()[:24]+'.jpg')
    if not target.exists():
        temporary=target.with_suffix('.tmp');temporary.write_bytes(fetch(url));temporary.replace(target)
    target.touch()
    prune_cache(cache)
    return str(target),'Apple Music · album artwork'

def main():
    folder=Path(sys.argv[1]).resolve();folder.mkdir(parents=True,exist_ok=True)
    cache=folder.parent.parent/'artist-cache';cache.mkdir(exist_ok=True)
    helper=Path(os.environ.get('HDMI_LAB_BUILD',str(HERE/'build')))/'TileRenderer'
    children=[]
    lock=threading.Lock();current={'key':None}
    with (folder/'renderer.log').open('wb') as render_log, (folder/'metadata.log').open('wb') as metadata_log:
        renderer=subprocess.Popen([str(helper),'--render',str(folder)],stdin=subprocess.PIPE,stdout=sys.stdout.buffer,stderr=render_log)
        children.append(renderer)
        def send(info):
            with lock:
                if renderer.poll() is None:
                    renderer.stdin.write((json.dumps(info)+'\n').encode());renderer.stdin.flush()
        def publish(info, paths, credit):
            with lock:
                if current['key']!=info['key'] or STOP.is_set():return
                value={**info,'imagePaths':paths,'artworkCredit':credit}
                if renderer.poll() is None:
                    renderer.stdin.write((json.dumps(value)+'\n').encode());renderer.stdin.flush()
                    (folder/'artwork-source.json').write_text(json.dumps({'source':credit,'images':len(paths)},indent=2))
        def load_image(info):
            if current['key']!=info['key'] or STOP.is_set():return
            paths=[];credit=''
            try:
                try:path,source=portrait(info,cache)
                except Exception:path,source=album_cover(info,cache)
                paths=[path];credit='Photos · '+source;publish(info,paths,credit)
            except Exception as error:
                print('Artwork unavailable: '+str(error),file=sys.stderr,flush=True)
            if current['key']!=info['key'] or STOP.is_set():return
            try:
                value=gallery(info,cache)
                if value['paths']:
                    publish(info,value['paths']+paths, value['credit']+(' / Apple Music' if paths else ''))
            except Exception as error:
                print('Gallery unavailable: '+str(error),file=sys.stderr,flush=True)
        pool=concurrent.futures.ThreadPoolExecutor(max_workers=2)
        watcher=subprocess.Popen([str(helper),'--now-playing'],stdout=subprocess.PIPE,stderr=metadata_log)
        children.append(watcher)
        def apply_metadata(info):
            with lock:
                if current['key']==info['key']:return
                current['key']=info['key']
            send({**info,'imagePaths':[],'artworkCredit':''})
            (folder/'now-playing.json').write_text(json.dumps(info,indent=2))
            pool.submit(load_image,info)
        def consume():
            for line in watcher.stdout:
                try:info=json.loads(line)
                except ValueError:continue
                apply_metadata(info)
        threading.Thread(target=consume,daemon=True).start()
        def player_metadata():
            # The player app writes this when it has Music access; the launchd
            # job itself may not. Ignore anything written before this session
            # started, so a stale song from last time never shows on the TV.
            path=folder.parent.parent/'music-now-playing.json'
            started=time.time()-2
            previous=None
            while not STOP.wait(.4):
                try:
                    modified=path.stat().st_mtime_ns
                    if modified!=previous and modified/1e9>=started:
                        info=json.loads(path.read_text());apply_metadata(info);previous=modified
                except (OSError,ValueError,KeyError):pass
        threading.Thread(target=player_metadata,daemon=True).start()
        for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,lambda *_:STOP.set())
        try:
            while not STOP.wait(.5):
                if renderer.poll() is not None or watcher.poll() is not None:raise RuntimeError('A visual helper stopped')
        finally:
            for p in children:
                if p.poll() is None:p.terminate()
            for p in children:
                try:p.wait(timeout=3)
                except subprocess.TimeoutExpired:p.kill();p.wait()
            pool.shutdown(wait=False,cancel_futures=True)

if __name__=='__main__':main()
