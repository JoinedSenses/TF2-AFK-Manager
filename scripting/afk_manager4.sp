#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <tf2>

#define AFKM_VERSION "5.0.0"
#define AFK_WARNING_INTERVAL 5
#define AFK_CHECK_INTERVAL 1.0
#define MAX_MESSAGE_LENGTH 250

enum {
	OBS_MODE_NONE,
	OBS_MODE_DEATHCAM,
	OBS_MODE_FREEZECAM
}

enum AFKImmunity: {
	AFKImmunity_None,
	AFKImmunity_Kick,
	AFKImmunity_Full
};

enum {
	CONVAR_VERSION,
	CONVAR_ENABLED,
	CONVAR_MOD_AFK,
	CONVAR_PREFIXSHORT,
	CONVAR_MINPLAYERSKICK,
	CONVAR_ADMINS_IMMUNE,
	CONVAR_TIMETOKICK,
	CONVAR_ARRAY_SIZE
}

AFKImmunity
	g_iPlayerImmunity[MAXPLAYERS+1];
char 
	g_Prefix[16];
int
	g_iPlayerUserID[MAXPLAYERS+1]
	, g_iAFKTime[MAXPLAYERS+1] = {-1, ...}
	, iButtons[MAXPLAYERS+1]
	, g_iPlayerTeam[MAXPLAYERS+1]
	, iObserverMode[MAXPLAYERS+1] = {-1, ...}
	, iObserverTarget[MAXPLAYERS+1] = {-1, ...}
	, g_iMapEndTime = -1
	, g_iAdminsImmunue = -1
	, g_iTimeToKick
	, g_iSpec_Team = 1;
bool
	bPlayerAFK[MAXPLAYERS+1] = {true, ...}
	, g_bEnabled
	, bKickPlayers;
Handle
	g_hAFKTimer[MAXPLAYERS+1];
ConVar
	hCvarAFK
	, hCvarEnabled
	, hCvarPrefixShort
	, hCvarMinPlayersKick
	, hCvarAdminsImmune
	, hCvarAdminsFlag
	, hCvarKickPlayers
	, hCvarTimeToKick
	, hCvarWarnTimeToKick;

// Plugin Information
public Plugin myinfo = {
    name = "[TF2] AFK Manager",
    author = "Rothgar, JoinedSenses",
    description = "Takes action on AFK players",
    version = AFKM_VERSION,
    url = "http://www.dawgclan.net"
};

public void OnPluginStart() {
	LoadTranslations("common.phrases");
	LoadTranslations("afk_manager.phrases");
	
	CreateConVar("sm_afkm_version", AFKM_VERSION, "Current version of the AFK Manager", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	hCvarEnabled = CreateConVar("sm_afk_enable", "1", "Is the AFK Manager enabled or disabled? [0 = FALSE, 1 = TRUE, DEFAULT: 1]", FCVAR_NONE, true, 0.0, true, 1.0);
	hCvarPrefixShort = CreateConVar("sm_afk_prefix_short", "0", "Should the AFK Manager use a short prefix? [0 = FALSE, 1 = TRUE, DEFAULT: 0]", FCVAR_NONE, true, 0.0, true, 1.0);
	hCvarMinPlayersKick = CreateConVar("sm_afk_kick_min_players", "6", "Minimum number of connected clients required for AFK kick to be enabled. [DEFAULT: 6]");
	hCvarAdminsImmune = CreateConVar("sm_afk_admins_immune", "1", "Should admins be immune to the AFK Manager? [0 = DISABLED, 1 = COMPLETE IMMUNITY, 2 = KICK IMMUNITY");
	hCvarAdminsFlag = CreateConVar("sm_afk_admins_flag", "", "Admin Flag for immunity? Leave Blank for any flag.");
	hCvarKickPlayers = CreateConVar("sm_afk_kick_players", "1", "Should the AFK Manager kick AFK clients? [0 = DISABLED, 1 = KICK ALL, 2 = ALL EXCEPT SPECTATORS, 3 = SPECTATORS ONLY]");
	hCvarTimeToKick = CreateConVar("sm_afk_kick_time", "120.0", "Time in seconds (total) client must be AFK before being kicked. [0 = DISABLED, DEFAULT: 120.0 seconds]");
	hCvarWarnTimeToKick = CreateConVar("sm_afk_kick_warn_time", "30.0", "Time in seconds remaining, player should be warned before being kicked for AFK. [DEFAULT: 30.0 seconds]");
	hCvarAFK = FindConVar("mp_idledealmethod");

	hCvarEnabled.AddChangeHook(CvarChange_Status);
	hCvarAFK.AddChangeHook(CvarChange_Status);
	hCvarPrefixShort.AddChangeHook(CvarChange_Status);
	hCvarAdminsImmune.AddChangeHook(CvarChange_Status);
	hCvarTimeToKick.AddChangeHook(CvarChange_Status);
	
	g_Prefix = hCvarPrefixShort.BoolValue ? "AFK" : "AFK Manager";
	g_iAdminsImmunue = hCvarAdminsImmune.IntValue;
	g_iTimeToKick = hCvarTimeToKick.IntValue;
	hCvarAFK.SetInt(0);
	
	HookEvent("player_disconnect", Event_PlayerDisconnectPost, EventHookMode_Post);
	HookEvent("player_team", Event_PlayerTeam);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_death", Event_PlayerDeathPost, EventHookMode_Post);
	AutoExecConfig(true, "afk_manager");
}

public void OnMapStart() {
	if (!g_bEnabled) {
		return;
	}
	AutoExecConfig(true, "afk_manager");
	if (g_iMapEndTime == -1) {
		return;
	}
	int iMapChangeTime = GetTime() - g_iMapEndTime;
	for (int i = 1; i <= MaxClients; i++) {
		if (g_iAFKTime[i] != -1) {
			g_iAFKTime[i] = g_iAFKTime[i] + iMapChangeTime;
		}
	}
	g_iMapEndTime = -1;
}

public void OnMapEnd() {
	if (!g_bEnabled) {
		return;
	}
	g_iMapEndTime = GetTime();
}

public void OnClientPostAdminCheck(int client) {
	if (!g_bEnabled) {
		return;
	}
	InitializePlayer(client);
	bKickPlayers = (AFK_GetClientCount() >= hCvarMinPlayersKick.IntValue);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
	if (!g_bEnabled || !IsClientConnected(client) || IsFakeClient(client) || g_hAFKTimer[client] == null) {
		return Plugin_Continue;
	}
	if (cmdnum <= 0) {
		return Plugin_Handled;
	}
	if (mouse[0] != 0 || mouse[1] != 0) {
		iButtons[client] = buttons;
		bPlayerAFK[client] = false;
		return Plugin_Continue;
	}
	if (iButtons[client] == buttons) {
		return Plugin_Continue;
	}
	if (IsClientObserver(client)) {
		if (iObserverMode[client] == -1) {
			iButtons[client] = buttons;
			return Plugin_Continue;
		}
		else if (iObserverMode[client] != 4) {
			iObserverMode[client] = GetEntProp(client, Prop_Send, "m_iObserverMode");
		}
		if ((iObserverMode[client] == 4 && iButtons[client] == buttons) || iButtons[client] == buttons) {
			return Plugin_Continue;
		}
	}
	iButtons[client] = buttons;
	bPlayerAFK[client] = false;
	return Plugin_Continue;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs) {
	if (g_bEnabled && g_hAFKTimer[client] != null) {
		ResetPlayer(client, false);
	}
	return Plugin_Continue;
}

public Action Event_PlayerDisconnectPost(Event event, const char[] name, bool dontBroadcast) {
	if (!g_bEnabled) {
		return Plugin_Continue;
	}
	int
		userID = event.GetInt("userid")
		, client = GetClientOfUserId(userID);

	if (0 < client <= MaxClients) {
		UnInitializePlayer(client);
	}
	else {
		for (int i = 1; i <= MaxClients; i++) {
			if (g_iPlayerUserID[i] == userID) {
				UnInitializePlayer(i);
			}
		}
	}
	bKickPlayers = (AFK_GetClientCount() >= hCvarMinPlayersKick.IntValue);
	return Plugin_Continue;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) {
	if (!g_bEnabled) {
		return Plugin_Continue;
	}
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && IsValidClient(client) && g_hAFKTimer[client] != null) {
		g_iPlayerTeam[client] = event.GetInt("team");
		if (g_iPlayerTeam[client] != g_iSpec_Team) {
			ResetObserver(client);
			ResetPlayer(client, false);
		}
	}
	return Plugin_Continue;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
	if (!g_bEnabled) {
		return Plugin_Continue;
	}
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && IsValidClient(client) && g_hAFKTimer[client] != null) {
		if (g_iPlayerTeam[client] == 0) {
			return Plugin_Continue;
		}
		if (!IsClientObserver(client) && IsPlayerAlive(client) && GetClientHealth(client) > 0) {
			ResetObserver(client);		
		}
	}
	return Plugin_Continue;
}

public Action Event_PlayerDeathPost(Event event, const char[] name, bool dontBroadcast) {
	if (!g_bEnabled) {
		return Plugin_Continue;
	}
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && IsValidClient(client) && g_hAFKTimer[client] != null) {
		if (IsClientObserver(client)) {
			iObserverMode[client] = GetEntProp(client, Prop_Send, "m_iObserverMode");
			iObserverTarget[client] = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
		}
	}
	return Plugin_Continue;
}

Action Timer_CheckPlayer(Handle Timer, int client) {
	if(!g_bEnabled) {
		return Plugin_Stop;
	}
	if (!IsClientInGame(client) || (GetEntityFlags(client) & FL_FROZEN)) {
		g_iAFKTime[client]++;
		return Plugin_Continue;
	}
	if (IsClientObserver(client)) {
		int m_iObserverMode = GetEntProp(client, Prop_Send, "m_iObserverMode");
		if (iObserverMode[client] == -1) {
			iObserverMode[client] = m_iObserverMode;
			return Plugin_Continue;
		}
		if (iObserverMode[client] != m_iObserverMode) {
			if (iObserverMode[client] == OBS_MODE_DEATHCAM) {
				iObserverMode[client] = m_iObserverMode;
				if (iObserverMode[client] != 7) {
					iObserverTarget[client] = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
				}
				return Plugin_Continue;
			}
			else if (iObserverMode[client] == OBS_MODE_FREEZECAM) {
				iObserverMode[client] = m_iObserverMode;
				if (iObserverMode[client] != 7) {
					iObserverTarget[client] = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
				}
				return Plugin_Continue;
			}
			iObserverMode[client] = m_iObserverMode;
			if (iObserverMode[client] != 7) {
				int m_hObserverTarget = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
				if (iObserverTarget[client] == client || !IsValidClient(m_hObserverTarget)) {
					iObserverTarget[client] = m_hObserverTarget;
					return Plugin_Continue;
				}
				iObserverTarget[client] = m_hObserverTarget;
			}
			SetClientAFK(client);
			return Plugin_Continue;
		}
		if (iObserverMode[client] != 7) {
			int m_hObserverTarget = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
			if (iObserverTarget[client] != m_hObserverTarget) {
				if (!(!IsValidClient(iObserverTarget[client]) || iObserverTarget[client] == client || !IsPlayerAlive(iObserverTarget[client]))){
					iObserverTarget[client] = m_hObserverTarget;
					SetClientAFK(client);
					return Plugin_Continue;
				}
				iObserverTarget[client] = m_hObserverTarget;
			}
		}
	}
	int Time = GetTime();
	if (!bPlayerAFK[client]) {
		SetClientAFK(client, (!IsPlayerAlive(client) && iObserverTarget[client] == client) ? false : true);
		return Plugin_Continue;
	}
	if (!bKickPlayers) {
		g_iAFKTime[client]++;
		return Plugin_Continue;
	}
	int
		AFKTime = (g_iAFKTime[client] >= 0) ? (Time - g_iAFKTime[client]) : 0
		, iKickPlayers = hCvarKickPlayers.IntValue;

	if (iKickPlayers <= 0) {
		return Plugin_Continue;
	}
	int AFKKickTimeleft = g_iTimeToKick - AFKTime;
	if (AFKKickTimeleft < 0 || AFKTime >= g_iTimeToKick) {
		return KickAFKClient(client);
	}
	else if (AFKTime%AFK_WARNING_INTERVAL == 0 && (g_iTimeToKick - AFKTime) <= hCvarWarnTimeToKick.IntValue) {
		PrintToChat(client, "%t", "Kick_Warning", AFKKickTimeleft);
	}
	return Plugin_Continue;
}		

Action KickAFKClient(int client) {
	char clientName[MAX_NAME_LENGTH];
	GetClientName(client, clientName, sizeof(clientName));
	KickClient(client, "[%s] %t", g_Prefix, "Kick_Message");
	PrintToChatAll("%t", "Kick_Announce", clientName);
	return Plugin_Handled;
}

void SetPlayerImmunity(int client, int type, bool AFKImmunityType = false) {
	if (AFKImmunityType && (AFKImmunity_None <= view_as<AFKImmunity>(type) <= AFKImmunity_Full)) {
		g_iPlayerImmunity[client] = view_as<AFKImmunity>(type);
		if (g_iPlayerImmunity[client] == AFKImmunity_Full) {
			ResetAFKTimer(client);
		}
		else {
			InitializeAFK(client);
		}
	}
	else if (!AFKImmunityType && (0 <= type <= 2 )) {
		switch (type) {
			case 1: {
				g_iPlayerImmunity[client] = AFKImmunity_Full;
				ResetAFKTimer(client);
				return;
			}
			case 2: {
				g_iPlayerImmunity[client] = AFKImmunity_Kick;
			}
			default: {
				g_iPlayerImmunity[client] = AFKImmunity_None;
			}
		}
		InitializeAFK(client);
	}
}

void ResetAFKTimer(int index) {
	delete g_hAFKTimer[index];
	ResetPlayer(index);
}

void ResetObserver(int index) {
	iObserverMode[index] = -1;
	iObserverTarget[index] = -1;
}

void ResetPlayer(int index, bool FullReset = true) {
	bPlayerAFK[index] = true;

	if (FullReset) {
		g_iPlayerUserID[index] = -1;
		g_iAFKTime[index] = -1;
		g_iPlayerTeam[index] = -1;
		ResetObserver(index);
	}
	else {
		g_iAFKTime[index] = GetTime();
	}
}

void SetClientAFK(int client, bool Reset = true) {
	if (Reset) {
		ResetPlayer(client, false);
	}
	else {
		bPlayerAFK[client] = true;
	}
}

void InitializeAFK(int index) {
	if (g_hAFKTimer[index] == null) {
		g_iAFKTime[index] = GetTime();
		g_iPlayerTeam[index] = GetClientTeam(index);
		g_hAFKTimer[index] = CreateTimer(AFK_CHECK_INTERVAL, Timer_CheckPlayer, index, TIMER_REPEAT);
	}
}

void InitializePlayer(int index) {
	if (!IsValidClient(index) ) {
		return;
	}
	int iClientUserID = GetClientUserId(index);
	if (iClientUserID != g_iPlayerUserID[index]) {
		ResetAFKTimer(index);
		g_iPlayerUserID[index] = iClientUserID;
	}
	if (g_iAdminsImmunue > 0 && g_iPlayerImmunity[index] == AFKImmunity_None && CheckAdminImmunity(index)) {
		SetPlayerImmunity(index, g_iAdminsImmunue);
	}
	if (g_iPlayerImmunity[index] != AFKImmunity_Full) {
		InitializeAFK(index);
	}
}

void UnInitializePlayer(int index) {
	ResetAFKTimer(index);
	g_iPlayerImmunity[index] = AFKImmunity_None;
}

void CvarChange_Status(ConVar cvar, const char[] oldvalue, const char[] newvalue) {
	if (StrEqual(oldvalue, newvalue)) {
		return;
	}
	if (cvar == hCvarEnabled) {
		hCvarEnabled.BoolValue ? EnablePlugin() : DisablePlugin();
	}
	else if (cvar == hCvarAdminsImmune) {
		g_iAdminsImmunue = StringToInt(newvalue);			
		for (int i = 1; i <= MaxClients; i++) {
			if (IsValidClient(i) && CheckAdminImmunity(i)) {
				SetPlayerImmunity(i, g_iAdminsImmunue);
			}
		}
	}
	else if (cvar == hCvarTimeToKick) {
		g_iTimeToKick = StringToInt(newvalue);
	}
	else if (cvar == hCvarPrefixShort) {
		g_Prefix = hCvarPrefixShort.BoolValue ? "AFK" : "AFK Manager";
	}
	else if (cvar == hCvarAFK && StringToInt(newvalue) != 0) {
		cvar.SetInt(0);
	}
}

void EnablePlugin() {
	g_bEnabled = true;
	for(int i = 1; i <= MaxClients; i++) {
		InitializePlayer(i);
	}
	bKickPlayers = (AFK_GetClientCount() >= hCvarMinPlayersKick.IntValue);
}

void DisablePlugin() {
	g_bEnabled = false;

	for(int i = 1; i <= MaxClients; i++) {
		UnInitializePlayer(i);
	}
}

int AFK_GetClientCount(bool inGameOnly = true) {
	int clients = 0;
	for (int i = 1; i <= MaxClients; i++) {
		if (((inGameOnly) ? IsClientInGame(i) : IsClientConnected(i)) && !IsClientSourceTV(i) && !IsFakeClient(i)) {
			clients++;
		}
	}
	return clients;
}

bool IsValidClient(int client) {
		return (IsClientInGame(client) && (0 < client <= MaxClients) && !IsFakeClient(client));
}

bool CheckAdminImmunity(int client) {
	int iUserFlagBits = GetUserFlagBits(client);
	if (iUserFlagBits > 0) {
		char sFlags[32];
		hCvarAdminsFlag.GetString(sFlags, sizeof(sFlags));
		return (StrEqual(sFlags, "") || (iUserFlagBits & (ReadFlagString(sFlags)|ADMFLAG_ROOT) > 0));
	}
	return false;
}