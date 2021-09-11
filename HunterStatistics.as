/*
The logic for finding checkpoints was taken from Phlarx checkpoint counter plugin [https://openplanet.nl/files/79]
*/

[Setting]
bool DebugLog = false;

Json::Value overviewStats;

bool isReset = false;
bool isSaved = false;

string currentMap;
string currentMapName;

int totalCPs;
int totalLaps;

int curCPIndex;

bool finished;
int curCPNum;
float[] cpTimes;
float curTime;
float curDistance;
int curLap;

// ########################################################## MAIN CODE ##########################################################

void Main()
{
	if(!IO::FolderExists(IO::FromDataFolder("HunterStats/maps/"))) {
		print("This seems to be the first start of Hunter Statistics. Creating folders...");
		IO::CreateFolder(IO::FromDataFolder("HunterStats\\maps\\"));
	}
	loadOverviewStats();
}

void Update(float dt) {
	if(GetApp().Editor !is null) {
		return; // No hunting in the editor. That would just mess up the stats. Maybe There will be separate stats for that later.
	}
	
	auto playground = cast<CSmArenaClient>(GetApp().CurrentPlayground);
	if(playground is null) {
		//logDebug("playground is null. resetting.");
		if(!finished) {
			saveRun();
		}
		reset();
		return;
	}
	
	auto map = playground.Map;
	if(map is null) {
		//logDebug("map is null. resetting");
		if(!finished) {
			saveRun();
		}
		reset();
		return;
	}
	
	auto players = playground.Players;
	if(players.Length <= 0) {
		return;
	}

	auto player = cast<CSmPlayer>(players[0]);
	if(player is null) {
		return;
	}
	
	isReset = false;
	isSaved = false;
	
	string newMapId = map.EdChallengeId;
	string newMapName = map.MapName;
	if(currentMap != newMapId) {
		logDebug("map changed. resetting.");
		reset();
		currentMap = newMapId;
		currentMapName = playground.Map.MapName;
		totalCPs = int(loadMapStats(currentMap)["totalCPs"]);
		initMap(newMapId, playground, player);
	}
	
	float newDistance = player.ScriptAPI.Distance;
	if(newDistance < curDistance) {
		// run has been reset (either manually or by finishing a run)
		logDebug("distance reset to 0.");
		if(!finished) {
			saveRun();
		}
		reset();
		return;
	}
	curDistance = newDistance;
	curTime = player.ScriptAPI.CurrentRaceTime;
	curLap = player.ScriptAPI.CurrentLapNumber;
    
	MwFastBuffer<CGameScriptMapLandmark@> landmarks = playground.Arena.MapLandmarks;
    if(curCPIndex != player.CurrentLaunchedRespawnLandmarkIndex) {
		curCPIndex = player.CurrentLaunchedRespawnLandmarkIndex;
		cpTimes.InsertLast(curTime);
		auto currentWaypoint = landmarks[curCPIndex].Waypoint;
		if(currentWaypoint is null) {
			// current waypoint is a start block nothing to do here
		} else if(currentWaypoint.IsFinish && !finished) {
			// current waypoint is a finish, so the run needs to be saved.
			logDebug("player finished map (distance: " + curDistance + ")");
			finished = true;
			saveRun();
		} else if(currentWaypoint.IsMultiLap && curLap >= totalLaps && !finished) {
			// current waypoint is a multilap start-finish block and the player has just completed the last lap
			finished = true;
			saveRun();
		} else {
			// current waypoint is a checkpoint
			curCPNum++;
		}
    }
}

void initMap(string mapId, CSmArenaClient& playground, CSmPlayer& player) {
	MwFastBuffer<CGameScriptMapLandmark@> landmarks = playground.Arena.MapLandmarks;
	
	curCPIndex = player.CurrentLaunchedRespawnLandmarkIndex;
	if(totalCPs >= 0) {
		return; // no need to find waypoints on that map again
	}
	totalCPs = 0;
	bool strictMode = true;
	
	array<int> links = {};
	for(uint i = 0; i < landmarks.Length; i++) {
		if(landmarks[i].Waypoint !is null && !landmarks[i].Waypoint.IsFinish && !landmarks[i].Waypoint.IsMultiLap) {
			// we have a CP, but we don't know if it is Linked or not
			if(landmarks[i].Tag == "Checkpoint") {
				totalCPs++;
			} else if(landmarks[i].Tag == "LinkedCheckpoint") {
				if(links.Find(landmarks[i].Order) < 0) {
					totalCPs++;
					links.InsertLast(landmarks[i].Order);
				}
			} else {
				// this waypoint looks like a CP, acts like a CP, but is not called a CP.
				if(strictMode) {
					warn("The current map, " + string(playground.Map.MapName) + " (" + playground.Map.IdName + "), is not compliant with checkpoint naming rules."
						+ " If the CP count for this map is inaccrate, please report this map to Phlarx#1765 on Discord.");
				}
				totalCPs++;
				strictMode = false;
			}
		}
	}
	
	if(playground.Map.TMObjective_IsLapRace) {
		totalLaps = playground.Map.TMObjective_NbLaps;
	}
}

void saveRun() {
	if(isSaved) {
		return;
	}
	isSaved = true;
	logDebug("save");
	if(curDistance < 0.01) { // arbitraty threshold to prevent saving if the player did not start driving
		return;
	}
	Json::Value runStats = Json::Object();
	runStats["time"] = curTime;
	runStats["distance"] = curDistance;
	runStats["cpTimes"] = Json::Array();
	for(int i = 0; i < cpTimes.Length; i++) {
		runStats["cpTimes"].Add(cpTimes[i]);
	}
	runStats["finished"] = finished;
	
	Json::Value mapStats = loadMapStats(currentMap);
	mapStats["totalTime"] = mapStats["totalTime"] + curTime;
	mapStats["runs"].Add(runStats);
	mapStats["totalCPs"] = totalCPs;
	int numRuns = mapStats["runs"].Length;
	if(finished) {
		int finishedRuns = mapStats["finishedRuns"];
		finishedRuns++;
		mapStats["finishedRuns"] = finishedRuns;
		mapStats["avgTime"] = (float(mapStats["avgTime"]) * (finishedRuns - 1) + float(runStats["time"])) / finishedRuns;
		mapStats["avgDistanceFin"] = (float(mapStats["avgDistanceFin"]) * (finishedRuns - 1) + float(runStats["distance"])) / finishedRuns;
	}
	mapStats["avgDistanceAll"] = (float(mapStats["avgDistanceAll"]) * (numRuns - 1) + float(runStats["distance"]));
	Json::ToFile(getMapFile(currentMap), mapStats);
	
	Json::Value ovStatsEntry = Json::Object();
	ovStatsEntry["mapname"] = mapStats["name"];
	ovStatsEntry["playtime"] = mapStats["totalTime"];
	ovStatsEntry["runs"] = numRuns;
	ovStatsEntry["avgTime"] = mapStats["avgTime"];
	overviewStats[currentMap] = ovStatsEntry;
	saveOverviewStats();
}

void reset() {
	if(isReset) {
		return;
	}
	isReset = true;
	logDebug("reset");
	curCPIndex = -1;
	curCPNum = -1;
	curTime = -1.0;
	curDistance = -1.0;
	curLap = -1;
	finished = false;
	for(int i = 0; i < cpTimes.Length; i++) {
		cpTimes.RemoveAt(0);
	}
}

Json::Value loadMapStats(string mapId) {
	Json::Value mapStats;
	string mapFile = getMapFile(mapId);
	if(!IO::FileExists(mapFile)) {
		mapStats = Json::Object();
		mapStats["id"] = mapId;
		mapStats["name"] = currentMapName;
		mapStats["runs"] = Json::Array();
		mapStats["finishedRuns"] = 0;
		mapStats["totalTime"] = 0;
		mapStats["avgTime"] = 0;
		mapStats["avgDistanceFin"] = 0;
		mapStats["avgDistanceAll"] = 0;
		mapStats["totalCPs"] = -1;
		if(mapId != currentMap) {
			throw("Trying to load a nonexistent map!");
		}
		Json::ToFile(mapFile, mapStats);
	} else {
		mapStats = Json::FromFile(mapFile);
		
	}
	return mapStats;
}

string getMapFile(string mapId) {
	return IO::FromDataFolder("HunterStats/maps/" + mapId + ".json");
}

void saveOverviewStats() {
	Json::ToFile(getOverviewFile(), overviewStats);
}

void loadOverviewStats() {
	string file = getOverviewFile();
	if(!IO::FileExists(file)) {
		overviewStats = Json::Object();
		Json::ToFile(file, overviewStats);
	} else {
		overviewStats = Json::FromFile(file);
	}
}

string getOverviewFile() {
	return IO::FromDataFolder("HunterStats/Overview.json");
}

// ########################################################## UI CODE ##########################################################


bool windowVisible;
bool mapWindowVisible;
string uiMapId;

void RenderInterface()
{
    if (windowVisible)
    {
        UI::Begin("Hunter Stats", windowVisible, UI::WindowFlags::NoCollapse | UI::WindowFlags::AlwaysAutoResize);

		//table layout: mapname, playtime, runs, avgTime
		
		string[]@ keys = overviewStats.GetKeys();
		
        if(UI::BeginTable("table_hunterstats", 4)) {
			UI::TableSetupColumn("Map");
			UI::TableNextColumn();
			UI::TableSetupColumn("Playtime");
			UI::TableNextColumn();
			UI::TableSetupColumn("Runs");
			UI::TableNextColumn();
			UI::TableSetupColumn("Average finish time");
			UI::TableHeadersRow();
			for(int i = 0; i < keys.Length; i++) {
				UI::TableNextRow();
				Json::Value rowStats = overviewStats[keys[i]];
				string mapname = rowStats["mapname"];
				UI::TableNextColumn();
				if(UI::Button(mapname)) {
					logDebug("Opening details: " + mapname);
					uiMapId = keys[i];
					mapWindowVisible = true;
				}
				int playtimeInt = rowStats["playtime"];
				string playtime = millisToTimeString(playtimeInt);
				int runsInt = rowStats["runs"];
				string runs = runsInt + "";
				int avgTimeInt = rowStats["avgTime"];
				string avgTime = millisToTimeString(avgTimeInt, true);
				
				UI::TableNextColumn();
				UI::Text(playtime);
				UI::TableNextColumn();
				UI::Text(runs);
				UI::TableNextColumn();
				UI::Text(avgTime);
			}
			UI::EndTable();
		}

        UI::End();
		
		if(mapWindowVisible) {
			Json::Value mapStats = loadMapStats(uiMapId);
			string mapName = mapStats["name"];
			UI::Begin("Stats - " + mapName, mapWindowVisible, UI::WindowFlags::NoCollapse | UI::WindowFlags::AlwaysAutoResize);
			
			UI::Text(mapName);
			
			UI::End();
		}
    }
}

void RenderMenu()
{
	if(UI::BeginMenu("Hunter Stats")) {
		if(UI::MenuItem("All Stats")) {
			windowVisible = true;
		}
		if(!isReset) {
			string totalTime = millisToTimeString(float(loadMapStats(currentMap)["totalTime"]));
			string menuLabel = currentMapName + " ( " + totalTime + " )";
			if(UI::MenuItem(menuLabel)) {
				logDebug("Opening details: " + currentMapName);
				uiMapId = currentMap;
				mapWindowVisible = true;
			}
		}
		
		UI::EndMenu();
	}
}

// ########################################################## UTIL CODE ##########################################################

void logDebug(string msg) {
	if(DebugLog) {
		print(msg);
	}
}

string millisToTimeString(float millis, bool addMillis = false) {
	float seconds = Math::Floor(millis / 1000);
	float minutes = Math::Floor(seconds / 60);
	float hours = Math::Floor(minutes / 60);
	millis = millis - (seconds * 1000);
	seconds = seconds - (minutes * 60);
	minutes = minutes - (hours * 60);
	
	string format = padWithZero(hours) + ":" + padWithZero(minutes) + ":" + padWithZero(seconds);
	
	if(addMillis) {
		format = format + "." + millis;
	}
	
	return format;
}

string padWithZero(float num) {
	if(num < 10) {
		return "0" + num;
	}
	return "" + num;
}