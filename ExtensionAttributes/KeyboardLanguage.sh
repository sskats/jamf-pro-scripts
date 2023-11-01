#!/bin/zsh

result=$(ioreg -arln AppleHIDKeyboardEventDriverV2)

if [[ -n $result ]]; then
   echo "<result>$(plutil -extract 0.KeyboardLanguage raw - <<< $result)</result>"
fi  

exit 0
