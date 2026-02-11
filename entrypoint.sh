#!/bin/bash
set -e
pipe=/tmp/tmod.pipe

echo -e "[SYSTEM] Shutdown Message set to: $TMOD_SHUTDOWN_MESSAGE"
echo -e "[SYSTEM] Save Interval set to: $TMOD_AUTOSAVE_INTERVAL minutes"

configPath=/terraria-server/serverconfig.txt
enabledpath=/data/tModLoader/Mods/enabled.json
modpath=/data/steamMods/steamapps/workshop/content/1281930
# Check Config
if [[ "$TMOD_USECONFIGFILE" == "Yes" ]]; then
    if [ -e /terraria-server/customconfig.txt ]; then
        echo -e "[!!] The tModLoader server was set to load with a config file. It will be used instead of the environment variables."
    else
        echo -e "[!!] FATAL: The tModLoader server was set to launch with a config file, but it was not found. Please map the file to /terraria-server/customconfig.txt and launch the server again."
        sleep 5s
        exit 1
    fi
else
  ./prepare-config.sh
fi
function generated_mods_cleanup () {
  rm -f $enabledpath
  # remove links to previously enabled mods
  rm -f /data/tModLoader/Mods/*.tmod
}
# Trapped Shutdown, to cleanly shutdown
function shutdown () {
  inject "say $TMOD_SHUTDOWN_MESSAGE"
  sleep 3s
  inject "exit"
  tmuxPid=$(pgrep tmux)
  tmodPid=$(pgrep --oldest --parent $tmuxPid)
  while [ -e /proc/$tmodPid ]; do
    sleep .5
  done
  rm $pipe
  generated_mods_cleanup
}
# Download Mods

if test -z "${TMOD_AUTODOWNLOAD}" ; then
    echo -e "[SYSTEM] No mods to download. If you wish to download mods at runtime, please set the TMOD_AUTODOWNLOAD environment variable equal to a comma separated list of Mod Workshop IDs."
    echo -e "[SYSTEM] For more information, please see the Github README."
    sleep 5s
else
    echo -e "[SYSTEM] Downloading Mods specified in the TMOD_AUTODOWNLOAD Environment Variable. This may hand a while depending on the number of mods..."
    # Convert the Comma Separated list of Mod IDs to a list of SteamCMD commands and call SteamCMD to download them all.
    /home/steam/steamcmd/steamcmd.sh +force_install_dir /data/steamMods +login ${STEAM_LOGIN:=anonymous} +workshop_download_item 1281930 `echo -e $TMOD_AUTODOWNLOAD | sed 's/,/ +workshop_download_item 1281930 /g'` +quit
    echo -e "[SYSTEM] Finished downloading mods."
fi
# Enable Mods
if test -z "${TMOD_ENABLEDMODS}" ; then
    echo -e "[SYSTEM] The TMOD_ENABLEDMODS environment variable is not set. Defaulting to the mods specified in /data/tModLoader/Mods/enabled.json"
    echo -e "[SYSTEM] To change which mods are enabled, set the TMOD_ENABLEDMODS environment variable to a comma seperated list of mod Workshop IDs."
    echo -e "[SYSTEM] For more information, please see the Github README."
    sleep 5s
else
  generated_mods_cleanup
  mkdir -p /data/tModLoader/Mods
  touch $enabledpath

  echo -e "[SYSTEM] Enabling Mods specified in the TMOD_ENABLEDMODS Environment variable..."
  echo '[' >> $enabledpath
  # Convert the Comma separated list of Mod IDs to an iterable list. We use this to drill through the directories and get the internal names of the mods.
  echo -e $TMOD_ENABLEDMODS | tr "," "\n" | while read LINE
  do
    echo -e "[SYSTEM] Enabling $LINE..."
    if [ ! -d $modpath/$LINE ]; then
      echo -e "[!!] Mod ID $LINE not found! Has it been downloaded? (Trying folder $modpath/$LINE)"
      exit 1
    fi
    modname=$(ls -1 $(ls -d $modpath/$LINE/*/|tail -n 1) | sed -e 's/\.tmod$//')
    if [ $? -ne 0 ]; then
      echo -e " [!!] An error occurred while attempting to load $LINE."
      exit 1
    fi
    # For each mod name that we resolve, write the internal name of it to the enabled.json file.
    echo "\"$modname\"," >> $enabledpath
    last_version_folder="$(find $modpath/$LINE -maxdepth 1 -type d | tail -n1)"
    actual_mod_location="${last_version_folder}/${modname}.tmod"
    mod_link_path="/data/tModLoader/Mods/${modname}.tmod"
    ln -s "${actual_mod_location}" "${mod_link_path}"
    echo -e "[SYSTEM] Enabled $modname ($LINE) using link: ${actual_mod_location} -> ${mod_link_path}"
  done
    echo ']' >> $enabledpath
    echo -e "\n[SYSTEM] Finished loading mods."
fi
echo "[SYSTEM] Enabled mods in $enabledpath:"
cat $enabledpath

# Startup command
server="/terraria-server/LaunchUtils/ScriptCaller.sh -server -tmlsavedirectory \"/data/tModLoader\" -steamworkshopfolder \"/data/steamMods/steamapps/workshop\" -config \"$configPath\""

# Trap the shutdown
trap shutdown TERM INT EXIT
echo -e "tModLoader is launching with the following command:"
echo -e $server

# Check if the pipe exists already and remove it.
if [ -e "$pipe" ]; then
  rm $pipe
fi

# Create the tmux and pipe, so we can inject commands from 'docker exec [container id] inject [command]' on the host
sleep 5s
mkfifo $pipe
tmux new-session -d "$server | tee $pipe"

# Call the autosaver
/terraria-server/autosave.sh &

# Infinitely print the contents of the pipe, so the container still logs the Terraria Server.
cat $pipe &
wait ${!}
