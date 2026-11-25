# Browser tests for the web app

Run from the repo root: `./venv/bin/python -m unittest discover -s review/tests/web` (about half a minute).

They drive `review/static/m` in headless Chromium through Playwright (`requirements-dev.txt`, then
`./venv/bin/python -m playwright install chromium` once), against their own server on 127.0.0.1:8813
over the real `trial_out/trial.db` (read-only) with a throwaway annotations.db and inbox. Without
Playwright or its Chromium every test skips. This folder has no `__init__.py`, so the main suite
(`discover -s review/tests -t .`) leaves it out. `webharness.py` has the server and the helpers.
