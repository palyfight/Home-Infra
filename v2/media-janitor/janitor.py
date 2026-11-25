#!/usr/bin/env python3
"""media-janitor: remove everything tagged "Trash" in Plex from the whole stack.

Every POLL_INTERVAL seconds it finds Plex movies/shows whose genres include the
trash tag and, for each one, in this order:

  1. qBittorrent - deletes the torrents (and their files) that Radarr/Sonarr
                   grabbed for it, found by the download hashes in arr history
  2. Radarr/Sonarr - deletes the movie/series and its files, and adds an import
                   exclusion so lists / Jellyseerr don't bring it back
  3. Jellyfin    - removes the matching library item
  4. Plex        - deletes the item, which also removes the tag (the work marker)

If any step fails, the later steps are skipped and the item is retried on the
next cycle. Plex is always last, so an item stays tagged until every other
service is clean. Every step treats "not found" as already done, so re-running
the same item is safe.

This script never deletes files itself: each service deletes its own data
through its API (so a Sonarr/Radarr recycle bin, if set, still applies).
"""

import logging
import os
import posixpath
import signal
import sys
import time
from dataclasses import dataclass, field

import requests

log = logging.getLogger("media-janitor")
TIMEOUT = 60


# --------------------------------------------------------------------------- config

def env(name, default=None):
    value = os.environ.get(name, "").strip()
    return value if value else default


def env_bool(name, default):
    value = env(name)
    if value is None:
        return default
    return value.lower() in ("1", "true", "yes", "on")


# --------------------------------------------------------------------------- model

@dataclass
class TrashItem:
    rating_key: str
    section_id: str
    kind: str  # "movie" or "show"
    title: str
    year: object
    tmdb: set = field(default_factory=set)
    tvdb: set = field(default_factory=set)
    imdb: set = field(default_factory=set)
    paths: list = field(default_factory=list)  # movie: media files, show: folders

    @property
    def name(self):
        return f"{self.title} ({self.year})" if self.year else self.title

    @property
    def folders(self):
        """Folders that hold this item (what Radarr/Sonarr call its path)."""
        if self.kind == "movie":
            return {norm(posixpath.dirname(p)) for p in self.paths}
        return {norm(p) for p in self.paths}


def norm(path):
    return posixpath.normpath(path) if path else ""


def parse_guids(guids):
    """Return {'tmdb': {...}, 'tvdb': {...}, 'imdb': {...}} from Plex guids.

    Handles new-agent guids ("tmdb://123") and legacy-agent guids
    ("com.plexapp.agents.themoviedb://123?lang=en").
    """
    schemes = {"tmdb": "tmdb", "themoviedb": "tmdb", "tvdb": "tvdb",
               "thetvdb": "tvdb", "imdb": "imdb"}
    ids = {"tmdb": set(), "tvdb": set(), "imdb": set()}
    for guid in guids:
        if not guid or "://" not in guid:
            continue
        scheme, rest = guid.split("://", 1)
        key = schemes.get(scheme.rsplit(".", 1)[-1])
        value = rest.split("?", 1)[0].split("/", 1)[0]
        if key and value:
            ids[key].add(value)
    return ids


# --------------------------------------------------------------------------- Plex

class Plex:
    def __init__(self, url, token):
        self.url = url.rstrip("/")
        self.s = requests.Session()
        self.s.headers.update({"X-Plex-Token": token, "Accept": "application/json"})

    def _get(self, path, **params):
        r = self.s.get(self.url + path, params=params, timeout=TIMEOUT)
        r.raise_for_status()
        return r.json().get("MediaContainer", {})

    def trash_items(self, tag_fields, tag):
        """Yield items carrying `tag` in any of `tag_fields` (genre / collection / label)."""
        seen = set()
        for section in self._get("/library/sections").get("Directory", []):
            if section.get("type") not in ("movie", "show"):
                continue
            sid = str(section["key"])
            for tag_field in tag_fields:
                try:
                    values = self._get(f"/library/sections/{sid}/{tag_field}").get("Directory", [])
                except requests.HTTPError as e:
                    log.debug("Section %s has no %s filter (%s)", sid, tag_field, e)
                    continue
                tag_ids = [str(v["key"]).rsplit("=", 1)[-1] for v in values
                           if str(v.get("title", "")).casefold() == tag.casefold()]
                for tag_id in tag_ids:
                    listing = self._get(f"/library/sections/{sid}/all", **{tag_field: tag_id})
                    for md in listing.get("Metadata", []):
                        rk = str(md["ratingKey"])
                        if rk not in seen:
                            seen.add(rk)
                            yield self._details(rk, sid)

    def _details(self, rating_key, section_id):
        md = self._get(f"/library/metadata/{rating_key}", includeGuids=1)["Metadata"][0]
        ids = parse_guids([g.get("id") for g in md.get("Guid", [])] + [md.get("guid")])
        if md.get("type") == "movie":
            paths = [p["file"] for m in md.get("Media", []) for p in m.get("Part", []) if p.get("file")]
        else:
            paths = [loc["path"] for loc in md.get("Location", []) if loc.get("path")]
        return TrashItem(rating_key, section_id, md.get("type"), md.get("title", "?"),
                         md.get("year"), ids["tmdb"], ids["tvdb"], ids["imdb"], paths)

    def delete(self, item):
        r = self.s.delete(f"{self.url}/library/metadata/{item.rating_key}", timeout=TIMEOUT)
        if r.ok or r.status_code == 404:
            return
        # Most often 403: "Allow media deletion" is off in Plex settings. Ask Plex
        # to rescan the folder instead; once the files are gone the item becomes
        # unavailable and Plex drops it on scan if "Empty trash automatically
        # after every scan" is on. Until then it stays tagged and gets retried.
        log.warning("Plex refused to delete %s (HTTP %s). Turn on Settings > Library > "
                    "'Allow media deletion'. Rescanning its folder instead.",
                    item.name, r.status_code)
        for folder in item.folders:
            self.s.get(f"{self.url}/library/sections/{item.section_id}/refresh",
                       params={"path": folder}, timeout=TIMEOUT)


# --------------------------------------------------------------------------- Radarr / Sonarr

class Arr:
    def __init__(self, name, url, api_key, resource):
        self.name = name
        self.url = url.rstrip("/")
        self.resource = resource  # "movie" (Radarr) or "series" (Sonarr)
        self.s = requests.Session()
        self.s.headers.update({"X-Api-Key": api_key})

    def _req(self, method, path, **kw):
        r = self.s.request(method, self.url + path, timeout=TIMEOUT, **kw)
        r.raise_for_status()
        return r.json() if r.content else None

    def find(self, item):
        matches = []
        folders = item.folders
        for e in self._req("GET", f"/api/v3/{self.resource}"):
            hit = (
                (e.get("tmdbId") and str(e["tmdbId"]) in item.tmdb)
                or (e.get("tvdbId") and str(e["tvdbId"]) in item.tvdb)
                or (e.get("imdbId") and e["imdbId"] in item.imdb)
                or (e.get("path") and norm(e["path"]) in folders)
            )
            if hit:
                matches.append(e)
        return matches

    def download_hashes(self, entry):
        if self.resource == "movie":
            records = self._req("GET", "/api/v3/history/movie", params={"movieId": entry["id"]})
        else:
            records = self._req("GET", "/api/v3/history/series", params={"seriesId": entry["id"]})
        return {r["downloadId"].lower() for r in records or [] if r.get("downloadId")}

    def delete(self, entry, add_exclusion):
        exclusion_param = "addImportExclusion" if self.resource == "movie" else "addImportListExclusion"
        r = self.s.delete(f"{self.url}/api/v3/{self.resource}/{entry['id']}",
                          params={"deleteFiles": "true", exclusion_param: str(add_exclusion).lower()},
                          timeout=TIMEOUT)
        if r.status_code != 404:
            r.raise_for_status()


# --------------------------------------------------------------------------- qBittorrent

class QBit:
    def __init__(self, url, user, password):
        self.url = url.rstrip("/")
        self.user, self.password = user, password
        self.s = requests.Session()
        self.s.headers.update({"Referer": self.url})
        self.logged_in = False

    def _login(self):
        if not self.user:
            return  # relies on qBittorrent's auth bypass for this subnet
        r = self.s.post(f"{self.url}/api/v2/auth/login",
                        data={"username": self.user, "password": self.password}, timeout=TIMEOUT)
        r.raise_for_status()
        if r.text.strip() == "Fails.":
            raise RuntimeError("qBittorrent login failed: check QBIT_USER / QBIT_PASS")
        self.logged_in = True

    def _req(self, method, path, **kw):
        if not self.logged_in:
            self._login()
        r = self.s.request(method, self.url + path, timeout=TIMEOUT, **kw)
        if r.status_code in (401, 403) and self.user:
            self._login()
            r = self.s.request(method, self.url + path, timeout=TIMEOUT, **kw)
        r.raise_for_status()
        return r

    def existing(self, hashes):
        if not hashes:
            return []
        found = self._req("GET", "/api/v2/torrents/info", params={"hashes": "|".join(sorted(hashes))}).json()
        # Never trust the server-side filter alone: an ignored filter would mean "every torrent".
        return [t for t in found if t.get("hash", "").lower() in hashes]

    def delete(self, hashes):
        self._req("POST", "/api/v2/torrents/delete",
                  data={"hashes": "|".join(sorted(hashes)), "deleteFiles": "true"})


# --------------------------------------------------------------------------- Jellyfin

class Jellyfin:
    def __init__(self, url, api_key):
        self.url = url.rstrip("/")
        self.s = requests.Session()
        self.s.headers.update({"Authorization": f'MediaBrowser Token="{api_key}"'})

    def find(self, item):
        item_type = "Movie" if item.kind == "movie" else "Series"
        r = self.s.get(f"{self.url}/Items", timeout=TIMEOUT, params={
            "Recursive": "true", "IncludeItemTypes": item_type, "Fields": "ProviderIds,Path"})
        r.raise_for_status()
        paths = {norm(p) for p in item.paths}
        matches = []
        for j in r.json().get("Items", []):
            pids = {k.lower(): str(v) for k, v in (j.get("ProviderIds") or {}).items() if v}
            hit = (
                pids.get("tmdb") in item.tmdb
                or pids.get("tvdb") in item.tvdb
                or pids.get("imdb") in item.imdb
                or (j.get("Path") and norm(j["Path"]) in paths)
            )
            if hit:
                matches.append(j)
        return matches

    def delete(self, item_id):
        r = self.s.delete(f"{self.url}/Items/{item_id}", timeout=TIMEOUT)
        if r.status_code != 404:
            r.raise_for_status()


# --------------------------------------------------------------------------- main loop

class Janitor:
    def __init__(self):
        plex_token = env("PLEX_TOKEN")
        if not plex_token:
            sys.exit("PLEX_TOKEN is required")
        self.plex = Plex(env("PLEX_URL", "http://localhost:32400"), plex_token)
        self.tag = env("TRASH_TAG", "Trash")
        self.tag_fields = [f.strip() for f in env("TAG_FIELDS", "genre").split(",") if f.strip()]
        if not self.tag_fields or set(self.tag_fields) - {"genre", "collection", "label"}:
            sys.exit("TAG_FIELDS must be a comma-separated list of: genre, collection, label")
        self.dry_run = env_bool("DRY_RUN", True)
        self.add_exclusion = env_bool("ADD_IMPORT_EXCLUSION", True)
        self.max_per_run = int(env("MAX_DELETES_PER_RUN", "25"))

        self.radarr = self._optional("Radarr", "RADARR_API_KEY",
                                     lambda k: Arr("Radarr", env("RADARR_URL", "http://localhost:7878"), k, "movie"))
        self.sonarr = self._optional("Sonarr", "SONARR_API_KEY",
                                     lambda k: Arr("Sonarr", env("SONARR_URL", "http://localhost:8989"), k, "series"))
        self.jellyfin = self._optional("Jellyfin", "JELLYFIN_API_KEY",
                                       lambda k: Jellyfin(env("JELLYFIN_URL", "http://localhost:8096"), k))
        self.qbit = QBit(env("QBIT_URL", "http://localhost:8080"), env("QBIT_USER"), env("QBIT_PASS", ""))

    @staticmethod
    def _optional(name, key_var, build):
        key = env(key_var)
        if not key:
            log.warning("%s not set: %s will be skipped", key_var, name)
            return None
        return build(key)

    def run_once(self):
        items = list(self.plex.trash_items(self.tag_fields, self.tag))
        if not items:
            log.debug("No items tagged %r", self.tag)
            return
        log.info("%d item(s) tagged %r in Plex%s", len(items), self.tag,
                 " [DRY RUN: nothing will be deleted]" if self.dry_run else "")
        if len(items) > self.max_per_run:
            log.warning("Only handling %d this cycle (MAX_DELETES_PER_RUN); the rest come next cycle",
                        self.max_per_run)
        for item in items[: self.max_per_run]:
            try:
                self.process(item)
            except Exception as e:
                log.error("Failed on %s, will retry next cycle: %s", item.name, e)

    def process(self, item):
        arr = self.radarr if item.kind == "movie" else self.sonarr

        # Collect everything first: arr history (the torrent hashes) is gone once the arr entry is deleted.
        entries = arr.find(item) if arr else []
        hashes = set()
        for e in entries:
            hashes |= arr.download_hashes(e)
        torrents = self.qbit.existing(hashes) if hashes else []
        jf_items = self.jellyfin.find(item) if self.jellyfin else []

        log.info("%s %s [%s]", "Would delete" if self.dry_run else "Deleting", item.name, item.kind)
        for t in torrents:
            log.info("  qBittorrent: %s", t.get("name"))
        for e in entries:
            log.info("  %s: %s  (%s)", arr.name, e.get("title"), e.get("path"))
        for j in jf_items:
            log.info("  Jellyfin: %s  (%s)", j.get("Name"), j.get("Path"))
        log.info("  Plex: %s", ", ".join(item.paths) or "(no files)")
        if arr and not entries:
            log.info("  (not found in %s)", arr.name)

        if self.dry_run:
            return

        if torrents:
            self.qbit.delete({t["hash"] for t in torrents})
        for e in entries:
            arr.delete(e, self.add_exclusion)
        for j in jf_items:
            self.jellyfin.delete(j["Id"])
        self.plex.delete(item)
        log.info("Done: %s", item.name)

    def loop(self, interval):
        log.info("Watching Plex tag %r (in: %s) every %ss (dry run: %s)",
                 self.tag, ", ".join(self.tag_fields), interval, self.dry_run)
        while True:
            try:
                self.run_once()
            except Exception as e:
                log.error("Cycle failed: %s", e)
            time.sleep(interval)


def main():
    logging.basicConfig(level=env("LOG_LEVEL", "INFO").upper(),
                        format="%(asctime)s %(levelname)-7s %(message)s")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    janitor = Janitor()
    if "--once" in sys.argv:
        janitor.run_once()
    else:
        janitor.loop(int(env("POLL_INTERVAL", "300")))


if __name__ == "__main__":
    main()
