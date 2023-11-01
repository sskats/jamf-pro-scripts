#!/bin/zsh

machineModel=$(system_profiler SPHardwareDataType  -json  | plutil -extract SPHardwareDataType.0.machine_model raw -)

if [[ $machineModel != *Book* ]]; then 
    result="${machineModel} has no battery."
else 
    permanentFailureStatus=$(ioreg -arln AppleSmartBattery | plutil -extract 0.PermanentFailureStatus raw -  )
    batteryHealth=$(system_profiler SPPowerDataType -json | plutil -extract SPPowerDataType.0.sppower_battery_health_info.sppower_battery_health raw -  )
    
    if [[ $permanentFailureStatus != "0" ]]; then
        result="Battery Permanent Failure, Code: ${permanentFailureStatus}\nBattery Health: ${batteryHealth}"
    else
        result="$batteryHealth"
    fi
fi

echo "<result>$result</result>"

exit 0
