#!/usr/bin/env python3
# Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
# Lab tool: builds an ATVQ payload from FilmTracker's real "Up Next" queue.
# Reads a COPY of the store (never the live file) and the app's PosterImages folder.
#
#   python3 ft-sample-payload.py out.json   then   swift atvq-send.swift out.json --sim

import base64, datetime, json, os, plistlib, shutil, sqlite3, sys, tempfile, uuid

CONTAINER = os.path.expanduser("~/Library/Containers/app.FilmTracker/Data/Library/Application Support")
UP_NEXT = "F1E2D3C4B5A647889900000000000001"

def unarchive(blob):
    """SwiftData stores [String] as a keyed archive wrapping JSON-encoded bytes."""
    if not blob:
        return []
    archive = plistlib.loads(blob)
    root = archive["$objects"][archive["$top"]["root"].data]
    return json.loads(root) if isinstance(root, (bytes, str)) else []

def duration_text(ms):
    try:
        minutes = round(float(ms or 0) / 60000)  # stored as milliseconds (text)
    except ValueError:
        return str(ms), None
    if minutes <= 0:
        return "", None
    h, m = divmod(minutes, 60)
    return (f"{h} hr {m} min" if h else f"{m} min"), minutes

def last_watched_text(stamp):
    try:
        date = datetime.datetime.strptime(stamp, "%Y.%m.%d")
    except (TypeError, ValueError):
        return ""
    months = (datetime.date.today().year - date.year) * 12 + datetime.date.today().month - date.month
    ago = "this month" if months <= 0 else f"{months} month{'s' * (months != 1)} ago" if months < 12 \
        else f"{months // 12} year{'s' * (months // 12 != 1)} ago"
    return f"{date.strftime('%B %Y')} ({ago})"

def main(out_path):
    work = tempfile.mkdtemp()
    for name in os.listdir(CONTAINER):
        if name.startswith("default.store"):
            shutil.copy(os.path.join(CONTAINER, name), work)
    db = sqlite3.connect(f"file:{os.path.join(work, 'default.store')}?mode=ro", uri=True)
    rows = db.execute("""
        SELECT f.ZID, f.ZNAME, f.ZRELEASEYEAR, f.ZGENRE, f.ZRATING, f.ZDURATION, f.ZDIGITALSOURCE,
               f.ZLASTWATCHED, f.ZDESCRIPTIONTEXT, f.ZDIRECTORS, f.ZSCREENWRITERS, f.ZCAST,
               f.ZPRODUCERS, f.ZCOMPOSER, f.ZPOSTERUID
        FROM ZLISTMEMBERSHIP m JOIN ZFILM f ON f.Z_PK = m.ZFILM JOIN ZLISTOBJECT l ON l.Z_PK = m.ZLIST
        WHERE hex(l.ZLISTID) = ? ORDER BY m.ZSORTORDER LIMIT 8""", (UP_NEXT,)).fetchall()
    films = []
    for (fid, name, year, genre, rating, dur, source, watched, synopsis,
         directors, writers, cast, producers, composers, poster_uid) in rows:
        text, minutes = duration_text(dur)
        poster_path = os.path.join(CONTAINER, "PosterImages", f"{poster_uid}.jpg")
        poster = base64.b64encode(open(poster_path, "rb").read()).decode() if os.path.exists(poster_path) else None
        films.append({
            "id": str(uuid.UUID(bytes=fid)) if isinstance(fid, bytes) and len(fid) == 16 else str(uuid.uuid4()),
            "title": name or "", "year": year or "", "genre": genre or "", "rating": rating or "",
            "duration": text, "runtimeMinutes": minutes, "source": source or "",
            "lastWatched": last_watched_text(watched), "synopsis": synopsis or "",
            "directors": unarchive(directors), "screenwriters": unarchive(writers), "cast": unarchive(cast),
            "producers": unarchive(producers), "composers": unarchive(composers), "poster": poster,
        })
    payload = {"version": 1, "dispatchedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "films": films}
    json.dump(payload, open(out_path, "w"))
    shutil.rmtree(work)
    print(f"Wrote {len(films)} films to {out_path}")

main(sys.argv[1] if len(sys.argv) > 1 else "ft-payload.json")
