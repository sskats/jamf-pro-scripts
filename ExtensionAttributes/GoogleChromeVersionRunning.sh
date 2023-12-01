#!/bin/zsh

runningVersion=$(ps -axo comm | grep -e '[G]oogle Chrome Helper (GPU)' | sed 's/.*\/Versions\/\([0-9.]*\)\/.*/\1/')

echo "<result>$runningVersion</result>"

exit 0 
