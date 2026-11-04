#!/bin/zsh

########################################
#
#   Warning: Always test this script before using it in production.
#
#   deploy-falcon-sensor-macos.sh
#       Installs the CrowdStrike Falcon sensor on macOS from Jamf Pro and keeps it at the target version
#       (install, upgrade, downgrade or reinstall, then license).
#       See README.md (English) / README.ja.md (Japanese) for setup and details.
#
#   API client permissions
#       - "Sensor Download: Read" (always)
#       - "Sensor update policies: Read" when the target is a policy ID or n, n-1, n-2 (default: n-1)
#       - "Sensor update policies: Write" to reveal the maintenance token for reinstall/downgrade
#
#   Parameter Values (Jamf Pro)
#       Parameter 4: Your environments CrowdStrike APIs Base URL. (e.g. https://api.crowdstrike.com )
#       Parameter 5: CrowdStrike APIs Client ID.
#       Parameter 6: CrowdStrike APIs Client Secret.
#       Parameter 7 *Optional: Target sensor. One of the following (Default: n-1)
#           - Sensor update policy ID (32 hex characters). The version set in the policy is used.
#           - n, n-1, n-2 : Latest build, one before latest, two before latest.
#           - Build number (e.g. 17003)
#           - Version number (e.g. 7.02, 7.02.17003)
#
#   Local testing
#       Run with -h for options.
#
#   Exit codes
#       0: Success
#       1: Invalid arguments
#       2: CrowdStrike API error (authentication, permissions, etc.)
#       3: Target sensor version not found
#       4: Download or checksum verification failed
#       5: Uninstall or install failed
#       6: License or load failed
#
########################################

setopt pipefail

SCRIPT_NAME="${0:t}"
WORK_DIR=""
PKG_FILE=""
FALCONCTL="/Applications/Falcon.app/Contents/Resources/falconctl"

BASE_URL="https://api.crowdstrike.com"
CLIENT_ID=""
CLIENT_SECRET=""
TARGET=""
DEFAULT_TARGET="n-1"
NO_INSTALL=false

usage(){
  cat <<EOF
Usage: ${SCRIPT_NAME} -i <client id> [-s <client secret>] [-v <target>] [-u <base url>] [-n] [-h]

  -u  CrowdStrike API base URL (default: ${BASE_URL})
  -i  API client ID
  -s  API client secret. If omitted, it is prompted for.
  -v  Target sensor (default: ${DEFAULT_TARGET}). One of:
        Sensor update policy ID (32 hex characters)
        n, n-1, n-2           latest build / one before / two before
        build number          e.g. 17003
        version number        e.g. 7.02, 7.02.17003
  -n  Download and verify only, and show what would be done. Do not install.
  -h  Show this help.

When run from Jamf Pro, parameters 4-7 are used instead (base URL, client ID, client secret, target).
EOF
}

##### Parameter Values
# Jamf Pro passes the target volume "/" as $1, followed by computer name, user name and parameters 4-11.
if [[ $1 == "/" ]]; then
  [[ -n $4 ]] && BASE_URL="$4"
  CLIENT_ID="$5"
  CLIENT_SECRET="$6"
  TARGET="$7"
else
  while getopts :u:i:s:v:nh OPT; do
    case $OPT in
      u) BASE_URL="$OPTARG" ;;
      i) CLIENT_ID="$OPTARG" ;;
      s) CLIENT_SECRET="$OPTARG" ;;
      v) TARGET="$OPTARG" ;;
      n) NO_INSTALL=true ;;
      h) usage; exit 0 ;;
      :) echo "Option -${OPTARG} requires an argument."; usage; exit 1 ;;
      ?) echo "Unknown option: -${OPTARG}"; usage; exit 1 ;;
    esac
  done

  if [[ -z $CLIENT_SECRET && -t 0 ]]; then
    read -rs "CLIENT_SECRET?Client secret: "
    echo
  fi
fi
BASE_URL="${BASE_URL%/}"
[[ -z $TARGET ]] && TARGET="$DEFAULT_TARGET"

if [[ -z $CLIENT_ID || -z $CLIENT_SECRET ]]; then
  echo "Client ID and client secret are required."
  usage
  exit 1
fi

if [[ ! $TARGET =~ '^([0-9a-fA-F]{32}|n(-[0-9]+)?|[0-9]+|[0-9]+(\.[0-9]+)+)$' ]]; then
  echo "Invalid target: $TARGET"
  usage
  exit 1
fi

if [[ $NO_INSTALL != "true" && $EUID -ne 0 ]]; then
  echo "Run as root (sudo) to install. Use -n to download and verify only."
  exit 1
fi

echo "Base URL: $BASE_URL"
echo "Client ID: $CLIENT_ID"
echo "Target: $TARGET"
echo "No install: $NO_INSTALL"
#####

die(){
  # $1: exit code, $2...: message
  local code=$1
  shift
  echo "Error: $*" >&2
  exit $code
}

cleanup(){
  # Runs on exit: remove the working directory and revoke the access token.
  [[ -n $WORK_DIR ]] && rm -rf "$WORK_DIR"
  if [[ -n $accessToken ]]; then
    # Pass the credentials and token via a curl config on stdin so they do not appear in the process list.
    printf 'user = "%s:%s"\ndata = "token=%s"\n' "$CLIENT_ID" "$CLIENT_SECRET" "$accessToken" |
      /usr/bin/curl -s -o /dev/null -X POST "$BASE_URL/oauth2/revoke" -K - \
      || echo "Warning: Failed to revoke the access token." >&2
  fi
  unset accessToken CLIENT_SECRET
}

plutilExtractHelper(){
  # Only extracting Plist with plutil.
  # Require key path and data.
  # Outputs the key of the specified path. Returns non-zero if the key is not found.
  # key path from first argument($1)
  # data from second argument($2) or stdin
 local data
 if [[ -n $2 ]]; then
    data=$2

 elif [[ -p /dev/stdin ]]; then
    data=$(cat - )

   else
    echo "Data input error" >&2
    return 1
  fi
  /usr/bin/plutil -extract $1 raw - <<< $data 2>/dev/null
}

getFalconStatus (){
  if [[ $1 == "installed" ]];then
    if [[ -e $FALCONCTL ]]; then
      echo "true"

    else
      echo "false"

    fi
  elif [[ $1 == "version" ]];then
    $FALCONCTL stats agent_info -p | plutilExtractHelper agent_info.version

  elif [[ $1 == "status" ]]; then
    $FALCONCTL stats agent_info -p | plutilExtractHelper agent_info.sensor_operational

  elif [[ $1 == "aid" ]]; then
    # falconctl shows the agent ID as "XXXXXXXX-XXXX-...". The API expects lowercase hex without dashes.
    $FALCONCTL stats agent_info -p | plutilExtractHelper agent_info.agentID | tr -d '-' | tr '[:upper:]' '[:lower:]'

  fi
}

falconApiRequest () {
  # Outputs the response body.
  # On a curl error or a non-2xx HTTP status, prints the API error message to stderr and returns 1.
  local response httpCode message
  if [[ $1 == "accesstoken" ]]; then
    # Pass the credentials via stdin so they do not appear in the process list.
    response=$(printf 'client_id=%s&client_secret=%s' "$CLIENT_ID" "$CLIENT_SECRET" |
      /usr/bin/curl -sS -L -w '\n%{http_code}' -X POST "$BASE_URL/oauth2/token" -H "accept: application/json" -d @-)

  elif [[ $1 == "maintenance-token" ]]; then
    # $2: agent ID of this host
    response=$(/usr/bin/curl -sS -L -w '\n%{http_code}' -X POST "$BASE_URL/policy/combined/reveal-uninstall-token/v1" -H "accept: application/json" -H "content-type: application/json" -H "authorization: Bearer $accessToken" \
      -d "{\"device_id\": \"$2\", \"audit_message\": \"Jamf Pro: reinstall Falcon sensor on $(/usr/sbin/scutil --get ComputerName)\"}")

  else
    response=$(/usr/bin/curl -sS -L -w '\n%{http_code}' "$BASE_URL$1"  -H  "accept: application/json" -H  "authorization: Bearer $accessToken")

  fi || { echo "API request failed: ${1%%\?*} (curl exit code $?)" >&2; return 1; }

  # The last line is the HTTP status code added by -w.
  httpCode=${response##*$'\n'}
  response=${response%$'\n'*}
  if [[ $httpCode != 2* ]]; then
    message=$(plutilExtractHelper errors.0.message "$response")
    echo "API request failed: ${1%%\?*} (HTTP $httpCode) $message" >&2
    return 1
  fi
  print -r -- "$response"
}

versionCompare () {
  # Compare version $1 with $2 (e.g. 7.40.21204). Outputs -1, 0 or 1. Missing components are treated as 0.
  local -a a b
  a=(${(s:.:)1})
  b=(${(s:.:)2})
  local i n=$(( ${#a} > ${#b} ? ${#a} : ${#b} ))
  for (( i=1; i<=n; i++ )); do
    (( ${a[i]:-0} > ${b[i]:-0} )) && { echo 1; return }
    (( ${a[i]:-0} < ${b[i]:-0} )) && { echo -1; return }
  done
  echo 0
}

downloadInstaller () {
  /usr/bin/curl -fsS -L -o $PKG_FILE "$BASE_URL/sensors/entities/download-installer/v1?id=$sha256"  -H "accept: application/json"  -H  "authorization: Bearer $accessToken"
}

resolveTargetVersion () {
  # Resolve $TARGET to a sensor version (e.g. 7.02.17003).
  # Returns 1 if not found, 2 on an API error.
  if [[ $TARGET =~ '^[0-9a-fA-F]{32}$' ]]; then
    # Sensor update policy ID
    local policy
    policy=$(falconApiRequest "/policy/entities/sensor-update/v2?ids=$TARGET") || return 2
    plutilExtractHelper resources.0.settings.sensor_version "$policy"
    return
  fi

  local i count
  if [[ $TARGET == n* ]]; then
    # n, n-1, n-2 tags are only available from the sensor update builds API.
    local sensorBuilds build
    sensorBuilds=$(falconApiRequest "/policy/combined/sensor-update-builds/v1?platform=mac") || return 2
    # plutil returns the number of elements for an array.
    count=$(plutilExtractHelper resources "$sensorBuilds")
    [[ $count =~ '^[0-9]+$' ]] || return 1

    for (( i=0; i<count; i++ )); do
      # build is like "17003|n-1|tagged|1", sensor_version is like "7.02.17003"
      build=$(plutilExtractHelper resources.${i}.build "$sensorBuilds")
      if [[ "|$build|" == *"|$TARGET|"* ]]; then
        plutilExtractHelper resources.${i}.sensor_version "$sensorBuilds" | grep -oE '[0-9]+(\.[0-9]+)+'
        return
      fi
    done
    return 1
  fi

  # Build number or version number: search the installer list (Sensor Download: Read only), newest first.
  local installers version
  installers=$(falconApiRequest "/sensors/combined/installers/v1?filter=platform%3A%22mac%22&sort=version%7Cdesc&limit=500") || return 2
  count=$(plutilExtractHelper resources "$installers")
  [[ $count =~ '^[0-9]+$' ]] || return 1

  for (( i=0; i<count; i++ )); do
    # version is like "8.10.21306"
    version=$(plutilExtractHelper resources.${i}.version "$installers")
    if [[ $TARGET =~ '^[0-9]+$' && ${version##*.} == $TARGET ]] \
      || [[ $TARGET == *.* && ( $version == $TARGET || $version == $TARGET.* ) ]]; then
      echo $version
      return
    fi
  done
  return 1
}

trap cleanup EXIT
# Make sure the EXIT trap also runs when interrupted.
trap 'exit 130' INT TERM

WORK_DIR=$(/usr/bin/mktemp -d /tmp/FalconSensor.XXXXXX) || die 4 "Failed to create a working directory."
PKG_FILE="$WORK_DIR/FalconSensorInstaller.pkg"

accessToken=$(falconApiRequest accesstoken | plutilExtractHelper access_token ) \
  || die 2 "Failed to get an access token. Check the base URL, client ID and client secret."

targetVersion=$(resolveTargetVersion) || { (( $? == 2 )) && die 2 "Failed to look up the target sensor: $TARGET" }
[[ $targetVersion =~ '^[0-9]+(\.[0-9]+)+$' ]] \
  || die 3 "Target sensor not found: $TARGET (For a policy ID, check that the policy has a sensor version set.)"
echo "Target version: $targetVersion"

# Decide what to do: install, upgrade, downgrade, reinstall or none
installedVersion=""
if [[ $(getFalconStatus installed) == "true" ]]; then
  installedVersion=$(getFalconStatus version | grep -oE '[0-9]+(\.[0-9]+)+')
  if [[ -z $installedVersion ]]; then
    [[ $NO_INSTALL == "true" ]] || die 5 "Failed to get the installed sensor version."
    echo "Warning: Could not read the installed sensor version. Run with sudo to check it."
    action="unknown"
  else
    case $(versionCompare $installedVersion $targetVersion) in
      -1) action="upgrade" ;;
      1)  action="downgrade" ;;
      0)  if [[ $(getFalconStatus status) == "true" ]]; then action="none"; else action="reinstall"; fi ;;
    esac
  fi
else
  action="install"
fi
echo "Installed version: ${installedVersion:-none}"
echo "Action: $action"

if [[ $action == "none" && $NO_INSTALL != "true" ]]; then
  echo "Already up to date."
  exit 0
fi

sha256=$(falconApiRequest "/sensors/combined/installers/v1?filter=platform%3A%22mac%22%2Bversion%3A%22$targetVersion%22" | plutilExtractHelper resources.0.sha256 ) \
  && [[ $sha256 =~ '^[0-9a-f]{64}$' ]] \
  || die 3 "Installer not found for version $targetVersion"
echo "sha256: $sha256"

CCID=$(falconApiRequest "/sensors/queries/installers/ccid/v1" | plutilExtractHelper resources.0 ) && [[ -n $CCID ]] \
  || die 2 "Failed to get the CCID."

downloadInstaller || die 4 "Failed to download the installer."

# Verify checksum
localchecksum=$(/usr/bin/shasum -a 256 $PKG_FILE | awk '{ print $1 }')
[[ $sha256 == $localchecksum ]] \
  || die 4 "Checksums did not match. Remote sha256: $sha256 Local checksum: $localchecksum"
echo "Checksums verified"

if [[ ${NO_INSTALL} == "true" ]]; then
  echo "No install (-n). Action that would be taken: $action"

else
  if [[ $action == "reinstall" || $action == "downgrade" ]]; then
    # The sensor must be uninstalled first. This needs the maintenance token.
    aid=$(getFalconStatus aid) && [[ -n $aid ]] || die 5 "Failed to get the agent ID of this host."
    maintenanceToken=$(falconApiRequest maintenance-token "$aid" | plutilExtractHelper resources.0.uninstall_token) \
      || die 2 "Failed to get the maintenance token."
    $FALCONCTL -v uninstall -t <<< $maintenanceToken
    uninstallResult=$?
    unset maintenanceToken
    (( uninstallResult == 0 )) || die 5 "Failed to uninstall the current sensor."
  fi

  /usr/sbin/installer -verboseR -pkg $PKG_FILE -target / || die 5 "Failed to install the sensor."
  sleep 10

  if [[ $action == "upgrade" ]]; then
    # The existing license is kept on upgrade. Wait until the new version is running.
    for i in {1..6}; do
      echo "Check attempt number: $i"

      [[ $(versionCompare "$(getFalconStatus version | grep -oE '[0-9]+(\.[0-9]+)+')" $targetVersion) == 0 \
        && $(getFalconStatus status) == "true" ]] && break

      (( i == 6 )) && die 6 "The upgraded sensor is not running."
      sleep 15
    done

  else
    for i in {1..6}; do
      echo "Register attempt number: $i"

      $FALCONCTL license $CCID && $FALCONCTL load && break

      (( i == 6 )) && die 6 "Failed to license and load the sensor."
      sleep 15
    done
  fi

fi

echo "Done."
exit 0
