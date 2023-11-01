#!/bin/zsh

installedVersion=$(plutil -extract KSVersion raw /Applications/Google\ Chrome.app/Contents/Info.plist)

echo "<result>$installedVersion</result>"

exit 0 
