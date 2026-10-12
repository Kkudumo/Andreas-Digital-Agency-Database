"""ADA Core prices for the static division websites (standard library only).

A division site's build asks this module for the price of a service by its ADA Core NAME; the module answers from ADA Core's public API when the build
is configured for it (ADA_API_URL and ADA_API_KEY in the build environment), and from the committed snapshot (build/prices.json) otherwise or for anything
the API does not return (a service that is not published yet, or is quote-based). So:

  * a price changed in ADA Hub reaches the site on its next build (Hub triggers one), with no page file edited;
  * a build NEVER breaks or goes blank because the API is down: it falls back to the snapshot and says so;
  * a service the site asks for that exists in neither place stops the build with a clear message (a typo must not publish "N$None").

Usage in a build script:
    from ada_prices import Prices
    P = Prices('consulting', Path(__file__).with_name('prices.json'))
    P.money('Business Check-up')        # 'N$199'
    P.from_money('Business Plan')       # 'From N$2,499'  (or 'N$2,499' when ADA Core says it is a fixed price)
Refresh the snapshot from the API (then commit it):  python3 ada_prices.py consulting build/prices.json --refresh
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


class Prices:
    def __init__(self, division: str, snapshot: Path, api_url: str | None = None, api_key: str | None = None, timeout: float = 15, log=print):
        self.division = division
        self.log = log
        self.entries: dict[str, dict] = {}
        snap = json.loads(Path(snapshot).read_text(encoding='utf8'))
        for s in snap['services']:
            self.entries[self._k(s['name'])] = s
        self.source = 'snapshot'
        api_url = api_url if api_url is not None else os.environ.get('ADA_API_URL')
        api_key = api_key if api_key is not None else os.environ.get('ADA_API_KEY')
        if api_url and api_key:
            self._overlay(api_url, api_key, timeout)
        elif api_url or api_key:
            log('ada_prices: ADA_API_URL and ADA_API_KEY must both be set; using the snapshot')
        else:
            log('ada_prices: no API configured; using the committed snapshot')

    @staticmethod
    def _k(name: str) -> str:
        return ' '.join(name.lower().split())

    def _overlay(self, api_url: str, api_key: str, timeout: float) -> None:
        url = api_url.rstrip('/') + '/api/public/services?division=' + self.division
        req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + api_key, 'Accept': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = json.loads(r.read().decode('utf8'))
            if not isinstance(data, list):
                raise ValueError('unexpected response shape')
        except (urllib.error.URLError, OSError, ValueError) as e:
            self.log(f'ada_prices: ADA Core API unavailable ({type(e).__name__}); using the committed snapshot')
            return
        changed, missing = [], []
        live = {self._k(s['name']): s for s in data}
        for k, s in live.items():
            if k not in self.entries:
                continue  # a service this site does not use
            old = self.entries[k].get('price')
            new = s.get('price')
            if new and (not old or (old['amount'], old.get('starting_price', False)) != (new['amount'], new.get('starting_price', False))):
                changed.append(f"{s['name']}: {old and old['amount']} -> {new['amount']}")
            if new:
                self.entries[k] = {**self.entries[k], 'price': new, 'billing_unit': s.get('billing_unit', self.entries[k].get('billing_unit'))}
        for k, e in self.entries.items():
            if e.get('price') and k not in live:
                missing.append(e['name'])
        self.source = 'api'
        self.log(f'ada_prices: using ADA Core ({len(live)} published services for {self.division}); {len(changed)} price(s) differ from the snapshot')
        for c in changed:
            self.log('  changed: ' + c)
        if missing:
            self.log('  not published in ADA Core (snapshot price kept): ' + ', '.join(sorted(missing)))

    def get(self, name: str) -> dict:
        try:
            return self.entries[self._k(name)]
        except KeyError:
            raise KeyError(f'ada_prices: no service called "{name}" for {self.division}; add it to ADA Core / the snapshot or fix the name') from None

    def amount(self, name: str) -> float:
        p = self.get(name).get('price')
        if not p:
            raise KeyError(f'ada_prices: "{name}" has no list price (it is quoted); use quoted() instead')
        return float(p['amount'])

    def is_starting(self, name: str) -> bool:
        p = self.get(name).get('price')
        return bool(p and p.get('starting_price'))

    def quoted(self, name: str) -> bool:
        return not self.get(name).get('price')

    @staticmethod
    def _fmt(a: float) -> str:
        return f'N${a:,.0f}' if a == int(a) else f'N${a:,.2f}'

    def money(self, name: str) -> str:
        """'N$1,499' or 'N$2,629.99': whole amounts without decimals, others with two."""
        return self._fmt(self.amount(name))

    def from_money(self, name: str) -> str:
        """'From N$149' when ADA Core says it is a starting price, otherwise 'N$149'."""
        return ('From ' if self.is_starting(name) else '') + self.money(name)

    def number(self, name: str) -> str:
        """The bare number ('1,499' / '2,629.99') for pages that print the currency separately."""
        return self.money(name)[2:]


def _cli(argv: list[str]) -> int:
    if len(argv) < 3 or '--refresh' not in argv:
        print(__doc__)
        return 2
    division, path = argv[1], Path(argv[2])
    p = Prices(division, path)
    if p.source != 'api':
        print('refresh needs ADA_API_URL and ADA_API_KEY and a reachable API')
        return 1
    out = {'division': division, 'source': 'ADA Core public API', 'services': sorted(p.entries.values(), key=lambda s: s['name'])}
    path.write_text(json.dumps(out, indent=1, ensure_ascii=False) + '\n', encoding='utf8')
    print(f'wrote {path}')
    return 0


if __name__ == '__main__':
    sys.exit(_cli(sys.argv))
