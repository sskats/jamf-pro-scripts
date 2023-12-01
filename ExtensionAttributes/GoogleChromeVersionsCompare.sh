#!/bin/zsh

installedVersion=$(plutil -extract KSVersion raw /Applications/Google\ Chrome.app/Contents/Info.plist)
runningVersion=$(ps -axo comm | grep -e '[G]oogle Chrome Helper (GPU)' | sed 's/.*\/Versions\/\([0-9.]*\)\/.*/\1/')

if [[ ! -f /Applications/Google\ Chrome.app/Contents/Info.plist ]]; then 
    result="Google Chrome not installed."
elif [[ -z $runningVersion ]]; then 
    result="Google Chrome not running."
elif [[ $installedVersion == $runningVersion ]]; then 
    result="Match"
else
    result="Mismatch"
fi

echo "<result>$result</result>"

exit 0 
