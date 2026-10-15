# DiveTracker

Peer into the Abyss

## Using the addon

### Interface

The dive interface automatically activates when a breathing device is equipped, such as from the back of a warship or the side of the adventurers clipper.
To activate the interface without a breathing apparatus, click the "Free Dive" checkbox.

To position the "Free Dive" checkbox and the main dive window, drag the provided handles on the side or on the top respectively.

### Main window

The main dive window has multiple useful information displayed:
-Speed: Your current maximum speed according to your stats screen
-Air Bar: The blue bar is the visual indication of the remaining air.
-Air left: Your current breathing device time left. It stays at 0:00 when there is no breathing device equipped. When air is below 1m, the air bar will flash red to alert the diver of imminent loss of air.
-Depth: How deep is the character underwater
-Bags Left: The amount of Recovery Pouches in the inventory
-Treasures Lifted: The amount of Sunken Treasure Chests that has been salvaged while the addon was loaded (does not require to have breathing apparatus equipped or free dive mode enabled)\
-Compass: To know where you are headed

### Waypoint Controls

The addon features a waypoint system in world coordinates. The addon comes with a pre-populated set of waypoints.

There are two buil tin waypoints available: Treasure chests and old jars. By selecting one of these, the waypoint actions will only apply to that set of waypoints

Available actions:
-Add: Adds a waypoint at the current character location
-Remove: Removes the closest waypoint to the character in 10m
-Range: Selects the display range of the activated waypoint group
-Next: Skips the currently tracked waypoint and jumps to the next. Does not mark the waypoint as visited.
-Reset: Resets the tracking mechanism and marks all waypoints not visited.

There are three checkboxes that interface with the waypoint system:
-Overlay: Turns the heads up display and rendering of waypoints in screen space on or off
-Track: Adds the next waypoint onto the compass
-Guides: Enables a dotted line indication to guide the diver to the next waypoint

The waypoint guide system targets the closest waypoint to the player and updates based on the players position. It generates a guide line up to 4 additional waypoints following the next closest location.
When the character is 10m or closer to a waypoint, it switches to "visited" state, and teh guide system will ignore these to avoid re-routing to already visited waypoints.

### Map

The map can be opened by pressing the "Map" button. It gives a visual indication of all the waypoints that belong to the selected group, and finds the top 5 most dense concentrations.
The most dense waypoint cluster will have a red circle around them, the less dense ones will have orange and blue.

The map can be zooned in and out using the scroll wheel, and panned around with the left mouse button.
It shows character, heading, and lines connecting the character to the top 5 most dense clusters with estimated distance.


## Credits

Ideas and waypoint gathering help from:
-Coffeeplease
-Yuzz
-Fayris

Assets are royalty free iamges from en.ac-illust.com and flaticon.com.

## AI usage

Claude was used for adding features, restructuring code, and finding and fixing bugs.