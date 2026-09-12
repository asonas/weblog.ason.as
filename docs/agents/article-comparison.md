# Public article comparison

Run the comparison explicitly when reviewing a public article layout change:

```sh
mise run article-comparison -- \
  --baseline BASELINE_COMMIT \
  --candidate CANDIDATE_COMMIT \
  --output /tmp/article-comparison
```

The command builds both commits from Git archives, publishes the same fixed article through each commit's production HTML generation path, captures the article at 390px and 1568px, and writes the report to `/tmp/article-comparison/report/index.html`.

Each run captures both commits again. It does not reuse screenshots from an earlier report. Use a new output directory for every run. The report records the resolved commits, fixture ID, browser version, viewport, fixed time, timezone, locale, and pixel differences.

The command exits unsuccessfully and records the failed stage and reason in `result.json` when a commit cannot be resolved, a build or server fails, the article or its media cannot be loaded, or a required screenshot is missing.

## Home page comparison

Run the home page comparison with the same commit and output arguments:

```sh
mise run home-comparison -- \
  --baseline BASELINE_COMMIT \
  --candidate CANDIDATE_COMMIT \
  --output /tmp/home-comparison
```

This variant builds the production frontend with fixed page-list, tag, archive, authentication, and image responses. It captures the home page at 390px and 1568px after the short and long tag fixtures and the article and diary cards have loaded. Missing fixed API responses or images fail the run instead of falling back to production data.
