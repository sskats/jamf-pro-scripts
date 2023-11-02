#!/bin/zsh

machineModel=$(system_profiler SPHardwareDataType  -json  | plutil -extract SPHardwareDataType.0.machine_model raw -)

if [[ $machineModel != *Book* ]]; then 
  result="${machineModel} has no battery."

else
  arch=$(/usr/bin/arch)

  if [[ "$arch" == "arm64" ]]; then
    result=$(system_profiler SPPowerDataType -json | plutil -extract SPPowerDataType.0.sppower_battery_health_info.sppower_battery_health_maximum_capacity raw - | sed -e 's/[^0-9]//g')

  elif [[ "$arch" == "i386" ]]; then
    resutlsBatteryInfo=$(ioreg -arln "AppleSmartBattery")
    maxCapacity=$(plutil -extract 0.MaxCapacity raw - <<< $resutlsBatteryInfo)
    designCapacity=$(plutil -extract 0.DesignCapacity raw - <<< $resutlsBatteryInfo)
    result=$(echo "scale=2; $maxCapacity/$designCapacity*100" | bc | awk '{printf("%d\n",$1)}')

  fi
fi

echo "<result>$result</result>"

exit 0
