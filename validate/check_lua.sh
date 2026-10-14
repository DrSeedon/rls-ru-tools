#!/bin/bash
# Prints every .lua under <overlay>/lua that fails a luajit syntax compile. No output = all good.
cd "$1" || exit 1
find lua -name '*.lua' 2>/dev/null | while read -r f; do luajit -b "$f" /dev/null 2>/dev/null || echo "FAIL $f"; done
