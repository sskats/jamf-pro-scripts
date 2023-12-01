#!/bin/zsh

machineModel=$(system_profiler SPHardwareDataType  -json  | plutil -extract SPHardwareDataType.0.machine_model raw -)

if [[ $machineModel == *Book* ]]; then
   result=$(ioreg -arln AppleHIDKeyboardEventDriverV2 | plutil -extract 0.KeyboardLanguage raw -)
fi

echo "<result>$result</result>"

exit 0
