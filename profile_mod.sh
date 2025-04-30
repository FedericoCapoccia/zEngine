#!/bin/sh

# Allow non-root applications to set GPU clock mode
# Make sure to enable for all GPU in system
for card in card0 card1 card2 card3
do
	fnam=/sys/class/drm/$card/device/power_dpm_force_performance_level
	if [ -f $fnam ]; then
		sudo chmod ugo+w $fnam
                echo 'profile_peak' | sudo tee $fnam
	fi
done
