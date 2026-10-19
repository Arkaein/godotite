# Releasing Godotite

How a release goes out, and the text and images for the store listings. `Arkaein` is the GitHub
account the repository lives under.

## GitHub, once

1. Create the repository on GitHub: **New repository**, name `godotite`, public, with **no**
   README, license or .gitignore (this repository has its own).
2. Push:

   ```
   git remote add origin git@github.com:Arkaein/godotite.git
   git push -u origin main
   ```

3. The **About** box (the gear beside it on the repository page):
   - **Description:** Nanite-style seamless level of detail for large static meshes in Godot 4
   - **Topics:** `godot`, `godot4`, `godot-addon`, `godot-plugin`, `godotengine`, `lod`,
     `level-of-detail`, `nanite`, `mesh-simplification`, `terrain`, `gamedev`, `csharp`,
     `gdscript`
   - Untick **Packages** and **Deployments** (unused); keep **Releases**.
4. **Settings › General › Social preview:** upload `media/social_preview.png` (1280×640). Links to
   the repository on LinkedIn and elsewhere show it.
5. **Settings › General › Features:** Issues on; Wiki and Projects off (the docs live in the
   repository). Discussions optional.
6. Pin the repository on your GitHub profile.

The front page is `README.md` at the root; the guide it links is `addons/godotite/README.md`, the
same file Asset Library users get. Every image in `media/` is made
as `media/README.md` describes; `media/tools/make_media.sh` redraws them.

## Public history

The history here is public and kept to real changes; the detailed history stays in the development
project. The first public commit is the whole of 0.9.0, squashed before the first push.

- **One commit per change worth announcing:** a release, or a fix or docs change copied over
  between releases. Messages say what changed for users, for example
  `Godotite 0.9.1: fix cracks on meshes with open edges`.
- **Several local commits before a push?** Fold them into one while they are unpushed:
  `git reset --soft origin/main`, then `git commit -m '...'`.
- **Never rewrite pushed commits:** that needs a force push and breaks every clone and fork. After
  a push, fix forward with a new commit.
- If commits should not show a personal email, set GitHub's no-reply address (Settings › Emails)
  for this repository only: `git config user.email '<id>+Arkaein@users.noreply.github.com'`.

## Each release

1. In the development project: everything committed, tested on the oldest and newest supported
   Godot versions.
2. Here: `./copy_addon.sh`, then try it as a user would (the demo, an import, an export), on each
   version's worktree too (`git -C ../godotite-4.7 checkout -f --detach main`).
3. Date the release in `addons/godotite/CHANGELOG.md` (in the development project, then copy) and
   check `version` in `addons/godotite/plugin.cfg`.
4. Commit, tag and push:

   ```
   git tag v0.9.0
   git push origin main v0.9.0
   ```

5. The download, exactly what the stores and GitHub's zip hold (only `addons/godotite/`, by
   `.gitattributes`):

   ```
   git archive --format=zip -o ../godotite-0.9.0.zip v0.9.0
   ```

6. On GitHub: a release from the tag, its notes the CHANGELOG entry, the zip attached.
7. Asset Library: a new version of the listing, Download Commit the tag's commit
   (`git rev-parse v0.9.0`).
8. Asset Store: a new version with the zip, its changelog the CHANGELOG entry.

## Listing

**Name:** Godotite

**Category (Asset Library):** 3D Tools. **Type (Asset Store):** Addon.

**Godot version:** 4.5 (Asset Library: one listing for 4.5, which 4.6 and later also install).
Asset Store: minimum 4.5, no maximum.

**License:** MIT.

**Repository:** `https://github.com/Arkaein/godotite`, issues at `.../issues`.

**Icon (Asset Library, square PNG, at least 128 px):**
`https://raw.githubusercontent.com/Arkaein/godotite/main/media/icon.png`

**Thumbnail (Asset Store, 16:9):** `media/thumbnail.png`.

**Tags (Asset Store):** lod, level of detail, mesh, terrain, optimization, 3d, csharp

**Summary (Asset Store):**

> Seamless level of detail for large static meshes: builds a mesh into a hierarchy of clusters and
> draws the coarsest that look right from the camera, with no cracks.

**Description** (plain text; the Asset Library shows no Markdown):

> Seamless level of detail for large static meshes in Godot, after the idea behind Unreal's Nanite.
>
> Godotite builds a mesh into a hierarchy of small clusters, from full detail down to a single
> coarse root. Every frame, a GodotiteLOD node draws the coarsest clusters that look right from the
> camera: full detail close up, far fewer triangles in the distance, and never a crack between
> them. A multi-million-triangle terrain or scan then costs what its on-screen detail costs, not
> what the whole mesh would.
>
> Features:
> - Build any mesh in a scene with a GodotiteBuilder node, or tick Build Lod when importing a
>   .glb, .gltf or .blend.
> - Materials, UVs, normals, tangents, vertex colors and custom channels carry over.
> - One project-wide quality setting, changeable at runtime like a graphics option.
> - Builds are deterministic and use every core; meshes over 4 million triangles build in pieces
>   to bound memory.
> - Debug views of clusters, levels and error, and tools to validate a build and measure its error.
> - A demo: a generated terrain with a fly camera and an overlay of what is drawn.
>
> Requirements: Godot 4.5 or later. Building needs the .NET version of Godot and a C# project;
> drawing is GDScript, so a game using Godotite can export without .NET.
>
> Start with the guide, addons/godotite/README.md, also on the repository's page.
>
> Godotite is an LLM-assisted project: most of its code and documentation were written by Claude
> (Anthropic), directed, tested and reviewed by the author.

**AI disclosure (Asset Store, required):**

> Most of the code (GDScript and C#) and the documentation were written by Claude, a large language
> model by Anthropic, at the author's direction; the author designed the features, tested every
> change in the editor and reviewed the results. The icon and thumbnail were drawn by a script
> Claude wrote, chosen and adjusted by the author.

**Screenshots:** in `media/` (its `.gdignore` keeps Godot from importing them): the demo in its
own colors, the cluster view and the level view, from one camera. Asset Library previews (up to
three) link them:

- `https://raw.githubusercontent.com/Arkaein/godotite/main/media/screenshot_material.png`
- `https://raw.githubusercontent.com/Arkaein/godotite/main/media/screenshot_cluster.png`
- `https://raw.githubusercontent.com/Arkaein/godotite/main/media/screenshot_levels.png`

The Asset Store takes them as uploads, with `media/hero.png` as a fourth.
