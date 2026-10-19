#!/usr/bin/env bash
# Mirrors addons/godotite/ from the development project into this repository, deletions included.
#
#   ./copy_addon.sh [path/to/development/project]   (default: ../hollowearth)
#
# Then open this project in the editor, try the demo, an import and an export, and commit.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source_project="${1:-$here/../hollowearth}"
source="$source_project/addons/godotite"

if [[ ! -f "$source/plugin.cfg" ]]; then
	echo "No addon at $source" >&2
	exit 1
fi

mkdir -p "$here/addons"
rsync -a --delete "$source/" "$here/addons/godotite/"

# The demo scene must ship unbuilt: after a Generate it names the development project's files.
demo="$here/addons/godotite/demo/godotite_demo.tscn"
if grep -q -e "godotite_mesh_path" -e "godotite_lod.gd" -e "dag_path" "$demo"; then
	echo "Warning: the demo scene was saved after a Generate; clear it in the source project" \
		"(GODOTITE.md, 'To make godotite_demo.tscn shippable again')." >&2
fi

version="$(sed -n 's/^version="\(.*\)"/\1/p' "$here/addons/godotite/plugin.cfg")"
echo "Copied Godotite $version from $source"
git -C "$here" status --short addons/godotite | tail -n 20
