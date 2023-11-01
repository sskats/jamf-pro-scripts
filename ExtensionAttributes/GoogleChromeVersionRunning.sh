#!/bin/zsh

runningVersion=$(ps -xo args | grep -e '[G]oogle Chrome Helper (GPU).app' | sed 's/.*\/Versions\/\([0-9.]*\)\/.*/\1/')

echo "<result>$runningVersion</result>"

exit 0 
