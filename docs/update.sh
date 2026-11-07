#!/usr/bin/env bash
DOCS_PATH=docs/_ign-web/
HASH=$(git rev-parse --short HEAD)
STDOCPATH=$DOCS_PATH/content/std.html
cd $(git rev-parse --show-toplevel)

cp docs/*.md	 docs/_ign-web/content/
cp docs/*.html docs/_ign-web/content/
rm docs/_ign-web/content/README.md

zig build -Dtarget=wasm32-wasi -Doptimize=small
cp ./zig-out/bin/revo.wasm ./docs/_ign-web/static/engine/revo-wasi.wasm
zig-out/bin/revo doc --html --splice ./src/base < "$STDOCPATH" > ./std-output.html
mv ./std-output.html $STDOCPATH

cd $DOCS_PATH
git add --all
git commit -m "auto update from #$HASH"

# read -p "do i push [y/n] " choice
# case "$choice" in 
#   y|Y ) echo "git push";;
#   n|N ) echo "ok";;
#   * ) echo "ok whatever";;
# esac
