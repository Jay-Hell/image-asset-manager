---
name: charged-glass
description: >
  Generate images in the Ionic "charged glass" house style: cinematic dark 3D renders of glass
  objects on a teal-charcoal ground, teal glow with a single orange accent, no text. For any use:
  Labs article heroes, decks, documents, LinkedIn posts. Trigger on "/charged-glass", "make an
  image for this page", "hero image", "house-style image", "image in the Labs style", "an image
  like the Plans one", or a page or deliverable that needs a picture. For a Labs page it also
  wires the hero and share image in and opens a PR.
---

# Charged glass — Ionic house-style images

The look behind the Labs heroes: Image Asset Manager, Deliverable Tracking, Plans, Ionic-Test
and TYPServer (`labs/assets/img/*-hero.jpg`, 23 Oct 2026). Look at two or three of those before
writing a prompt. They are the reference set, and this file only describes them.

## 1. Find the concept

One image, one visual metaphor, taken from the subject's central claim, not its topic. Read
the standfirst or opening paragraph, then ask what changes because the thing exists.

- **Physical glass objects stand in for abstract things:** cards for deliverables, bars for
  tasks, panes for screens, a block for an evidence pack.
- **Movement or structure carries the story:** chaos settling into order, a path threading
  through, threads joining parts, copies receding into depth.
- **Orange marks one thing only,** the element the story turns on: the next item, the
  milestone, the signed seal. Everything else glows teal.
- **Describe shapes geometrically, not by name.** "Diamond" gave a gemstone on Plans. Write
  "a flat, faceted rhombus marker" for a milestone diamond.
- **Never ask for text, numbers, ticks or UI detail.** The model fills those in badly.

The four concepts that worked, on 23 Oct 2026:

| Page | Concept |
|---|---|
| Deliverable Tracking | Scattered glass cards drift right and settle into long ordered teal columns; one card at the front glows orange as "next" |
| Plans | Gantt chart of floating glass bars linked by light threads (dependencies), leading to an orange milestone with small deliverable tiles beneath |
| Ionic-Test | A teal light trail threads a curving line of glass browser panes, ending at a glass evidence block sealed with an orange disc |
| TYPServer | A dark server stack edge-lit in teal, with translucent copies fading behind it (layered backups) |

Unless John asks to see options first, choose the concept and generate it. Say which concept
you chose in one line when you show the result.

## 2. Write the prompt

Start with `Cinematic dark 3D render, <ratio>.`, then two to four sentences of scene and a
`Theme:` line, then this style block verbatim:

> Lighting: low-key, deep shadows, teal rim light and glow, a single warm orange accent, subtle
> reflections on a matte dark floor, faint haze, shallow depth of field. Minimal, premium,
> abstract technology aesthetic. Colour palette: near-black teal-charcoal background, cyan-teal
> glow (#3fd1c0), warm orange accent (#ff8a2a). No text, no letters, no numbers, no logos, no
> people.

Add any subject-specific bans to that last sentence, such as "no tick symbols" or "no dates".

| Destination | Ratio | Notes |
|---|---|---|
| Labs article hero and og:image | 16:9 | Comes out at 1376×768 |
| Deck slide (full bleed) | 16:9 | Leave dark space on one side if text will sit on it |
| LinkedIn post | 1:1 or 4:5 | |
| Document banner | 21:9 | |

## 3. Generate

1. **Image Asset Manager (IAM) first:** call `mcp__image-asset-manager__list_generation_options`.
   The proxy opens the app if it is closed, so this should answer. Generate with
   `mcp__image-asset-manager__generate` (`quality: standard`, `project: "Labs"`, or the project
   the request names; tags `charged-glass` plus the subject) so the image lands in the library
   filed to its project. The project must already exist: if `generate` refuses it, read the list
   in the error and choose from it. Make a new one with `create_project` only when John has asked
   for it. If IAM still fails, say what it said and fall back.
2. **Fallback, the `mcp-image` server:** `mcp__mcp-image__generate_image` with `aspectRatio`,
   `purpose` (where the image will be used) and a `fileName`. It runs the same Nano Banana
   model. It saves to `~/Documents/1.1.Claude/Assets/images/`, always as `.jpg` whatever the
   extension you ask for. **Then import the result into IAM:** `mcp__image-asset-manager__import_asset`
   with the saved file's absolute `path`, the full `prompt` you sent, `project` (as in step 1),
   `tags: ["charged-glass", <subject>]`, `provider: "google"` and `model` as the server reports
   it. Leave `actual_cost_gbp` out unless the server reports a cost. From a script,
   `iam import <file> --project Labs --prompt "…" --tag charged-glass` does the same. If IAM is
   down, say the image is not yet in the library.
3. If several images are needed, generate them in parallel.
4. **If the style drifts** (too bright, flat, cartoonish), regenerate once with one or two of
   the reference heroes as style references (IAM `references` with `role: style_anchor`, or
   `inputImagePaths`), and add "match the lighting and palette of the reference; do not copy
   its composition".

## 4. Check before showing

Open each image and check it against this list. Regenerate any that fails, at most twice, then
show it to John with the fault stated.

- No text, glyphs, numbers or fake interface anywhere.
- Background is dark teal-charcoal, not black, grey or blue.
- Exactly one orange focal element, and it is the thing the story turns on.
- The concept reads at thumbnail size.

## 5. Deliver to the destination

**Labs page** (repo `Jay-Hell/ionic-labs`, working copy
`~/Sync/1.1.Claude/1. Project Work/Ionic/Migrate Website/labs/`; read its README):

1. Make a feature branch from an up-to-date `main`.
2. Compress: `sips -s format jpeg -s formatOptions 55 <original> --out assets/img/<slug>-hero.jpg`.
   The target is about 70–115 KB. Look at the compressed file once.
3. Add `<div class="article-hero"><img src="/assets/img/<slug>-hero.jpg" alt="…" width="1376"
   height="768"></div>` straight after the `<p class="standfirst">`. The alt text describes
   what is in the picture, in one sentence.
4. Point `og:image` and `twitter:image` at the absolute URL of the hero, and set
   `og:image:width`/`height` to 1376/768.
5. Run `npm test`, serve locally and fetch each image path, then commit, push and open a PR.
   **Never merge or deploy without John asking.** Deploys follow the README: a clean clone,
   `npx wrangler deploy`, then check the live bytes match.

**Deck, document or post:** save the full-size original to the task folder
(`~/Sync/1.1.Claude/1. Project Work/{Client}/{Project}/{Task}/`), named for its subject. Don't
compress it unless asked.

**Every time:** if IAM was up, call `mark_asset_used` with the destination. Give John the path
or the PR link, plus one line per image naming its concept.
