# activerecord-materialized — brand assets

The mark is **Materialized Layer**: a solid, pre-computed result (the cream cap and its
rows) sitting on top of a live database — the view, *materialized*. Crimson-native to the
Rails ecosystem.

## Files

```
assets/
├─ favicon.ico                 multi-res (16/32/48) — drop at repo/site root
├─ favicon-16.png              ┐
├─ favicon-32.png              ┘ PNG favicons
├─ apple-touch-icon.png        180×180 (iOS home screen)
├─ svg/
│  ├─ mark.svg                 primary, full-color (use this everywhere it fits)
│  ├─ avatar.svg               rounded-square badge — GitHub org / social avatar
│  ├─ mark-mono.svg            one-color line, crimson
│  ├─ mark-black.svg           one-color line, ink (#181113)
│  └─ mark-white.svg           one-color line, paper (for dark backgrounds)
└─ png/
   ├─ mark-32 / 48 / 64 / 128 / 256 / 512.png        transparent
   ├─ avatar-16 … 512.png                            transparent corners
   ├─ lockup-horizontal.png                          README banner (light)
   └─ lockup-horizontal-dark.png                     README banner (dark)
```

## README banner

```md
<p align="center">
  <img src="assets/png/lockup-horizontal.png" alt="activerecord-materialized" width="430">
</p>
```

## Favicons (HTML)

```html
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/favicon-32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/assets/favicon-16.png">
<link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
```

## Color

| Token       | Hex       |
|-------------|-----------|
| Crimson     | `#CD1F2D` |
| Deep        | `#8F1320` |
| Outline     | `#6E0C18` |
| Stored cap  | `#FBF4F1` |
| Ink         | `#181113` |
| Accent\*    | `#16B3C7` |

\* Cyan accent is reserved for sibling gems, docs links, and performance states — it is
intentionally absent from the core mark to keep it Rails-native.

## Usage notes

- Prefer `svg/mark.svg` whenever the medium supports it — it's resolution-independent.
- Below ~20px (browser tabs), use the solid **avatar** build; the open mark's line detail
  muddies at that scale.
- Keep clearspace around the mark equal to the height of the cream cap.
- Don't recolor the mark outside the one-color variants provided.

## Where each asset is used (this repo)

| Surface | Asset | How |
|---------|-------|-----|
| README banner | `png/lockup-horizontal.png` + `-dark.png` | `<picture>` with a `prefers-color-scheme: dark` source, referenced by **absolute** `raw.githubusercontent.com/.../main/...` URL so it renders on GitHub *and* on RubyDoc.info. |
| GitHub social preview | `png/avatar-512.png` | Repo **Settings → Social preview** (manual upload — GitHub has no API for it). |
| GitHub / org avatar | `svg/avatar.svg` (or `png/avatar-256.png`) | Org/profile **Settings** (manual upload). |
| Favicons (future docs site) | `favicon.ico`, `favicon-16/32.png`, `apple-touch-icon.png` | `<link rel="icon">` tags — see the HTML snippet above. |

## Shipping the logo with the gem (prior art)

Researched against rubygems.org and RubyDoc.info before wiring anything up:

- **rubygems.org does not render a per-gem logo** and does **not** render the README — a
  gem's page shows only the gemspec `summary`/`description`, dependency list, owner, and the
  `metadata` link set (homepage, source, changelog, docs, bug tracker). There is **no**
  `logo_uri`/`icon_uri` gemspec field.
- The logo therefore reaches developers through the two surfaces that *do* render the README:
  the **GitHub repo homepage** and **RubyDoc.info** (linked from the gem page's
  *Documentation*). Both resolve the banner because the README references it by **absolute
  raw URL**, not a relative path.
- Consequently the image binaries are intentionally **kept out of the published `.gem`**
  (`activerecord-materialized.gemspec` packages only `lib/` + top-level docs). Shipping them
  would bloat the package for zero benefit, since nothing in the gem-install path renders them.
  They live in the repo only.
