#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <cstrike>
#include <dhooks>
#include <navmesh>

#define MAX_TEMPLATE_NAME 32

StringMap g_hBotTemplates;

bool g_bIsProBot[MAXPLAYERS + 1];
bool g_bIsIntermediateBot[MAXPLAYERS + 1];
bool g_bUncrouch[MAXPLAYERS + 1];

int g_iTarget[MAXPLAYERS + 1];
int g_iPrevTarget[MAXPLAYERS + 1];
int g_iActiveWeapon[MAXPLAYERS + 1];
int g_iProfileRank[MAXPLAYERS + 1];
int g_iPlayerColor[MAXPLAYERS + 1];
int g_iBotTargetSpotOffset;
int g_iFireWeaponOffset;
int g_iEnemyVisibleOffset;
int g_iBotEnemyOffset;
int g_iBotDispositionOffset;
int g_iProfileRankOffset;
int g_iPlayerColorOffset;

float g_fBotOrigin[MAXPLAYERS + 1][3];
float g_fTargetPos[MAXPLAYERS + 1][3];
float g_fShootTimestamp[MAXPLAYERS + 1];
float g_fCrouchTimestamp[MAXPLAYERS + 1];

Handle g_hBotMoveTo;
Handle g_hLookupBone;
Handle g_hGetBonePosition;
Handle g_hBotIsVisible;
Handle g_hBotIsHiding;
Handle g_hBotEquipBestWeapon;
Handle g_hBotSetLookAt;
CNavArea g_pCurrArea[MAXPLAYERS + 1];

static char g_szBoneNames[][] =
{
	"neck_0",
	"pelvis",
	"spine_0",
	"spine_1",
	"spine_2",
	"spine_3",
	"clavicle_l",
	"clavicle_r",
	"arm_upper_L",
	"arm_lower_L",
	"hand_L",
	"arm_upper_R",
	"arm_lower_R",
	"hand_R",
	"leg_upper_L",
	"leg_lower_L",
	"ankle_L",
	"leg_upper_R",
	"leg_lower_R",
	"ankle_R"
};

enum RouteType
{
	DEFAULT_ROUTE = 0,
	FASTEST_ROUTE,
	SAFEST_ROUTE,
	RETREAT_ROUTE
}

enum PriorityType
{
	PRIORITY_LOWEST = -1,
	PRIORITY_LOW,
	PRIORITY_MEDIUM,
	PRIORITY_HIGH,
	PRIORITY_UNINTERRUPTABLE
}

enum DispositionType
{
	ENGAGE_AND_INVESTIGATE,
	OPPORTUNITY_FIRE,
	SELF_DEFENSE,
	IGNORE_ENEMIES,
	NUM_DISPOSITIONS
}

public Plugin myinfo =
{
	name = "betterbotsplusDM",
	author = "Rxpev",
	description = "Stripped BetterBotsPlus-LIGA deathmatch build: aim and movement only.",
	version = "1.0.0",
	url = "http://steamcommunity.com/id/rxpev"
};

public void OnPluginStart()
{
	g_hBotTemplates = new StringMap();

	HookEventEx("player_spawn", OnPlayerSpawn);

	LoadSDK();
	LoadDetours();
}

public void OnMapStart()
{
	LoadBotTemplates();

	g_iProfileRankOffset = FindSendPropInfo("CCSPlayerResource", "m_nPersonaDataPublicLevel");
	g_iPlayerColorOffset = FindSendPropInfo("CCSPlayerResource", "m_iCompTeammateColor");
	SDKHook(GetPlayerResourceEntity(), SDKHook_ThinkPost, OnThinkPost);

	for (int i = 1; i <= MaxClients; i++)
		g_iPlayerColor[i] = -1;
}

public void OnMapEnd()
{
	SDKUnhook(GetPlayerResourceEntity(), SDKHook_ThinkPost, OnThinkPost);
}

public void OnClientPostAdminCheck(int client)
{
	g_iProfileRank[client] = GetRandomInt(1, 40);
	ClassifyBot(client);
}

public void OnClientDisconnect(int client)
{
	if (client <= 0 || client > MaxClients)
		return;

	g_bIsProBot[client] = false;
	g_bIsIntermediateBot[client] = false;
	g_bUncrouch[client] = false;
	g_iTarget[client] = -1;
	g_iPrevTarget[client] = -1;
	g_iProfileRank[client] = 0;
	g_iPlayerColor[client] = -1;
	g_fTargetPos[client][0] = 0.0;
	g_fTargetPos[client][1] = 0.0;
	g_fTargetPos[client][2] = 0.0;
}

public void OnPlayerSpawn(Event eEvent, const char[] szName, bool bDontBroadcast)
{
	int client = GetClientOfUserId(eEvent.GetInt("userid"));
	SetPlayerTeammateColor(client);
}

public void OnThinkPost(int iEnt)
{
	SetEntDataArray(iEnt, g_iProfileRankOffset, g_iProfileRank, MAXPLAYERS + 1);
	SetEntDataArray(iEnt, g_iPlayerColorOffset, g_iPlayerColor, MAXPLAYERS + 1);
}

public Action OnPlayerRunCmd(int client, int &iButtons, int &iImpulse, float fVel[3], float fAngles[3], int &iWeapon, int &iSubtype, int &iCmdNum, int &iTickCount, int &iSeed, int iMouse[2])
{
	if (!IsValidClient(client) || !IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	if (!g_bIsProBot[client] && !g_bIsIntermediateBot[client])
		return Plugin_Continue;

	GetClientAbsOrigin(client, g_fBotOrigin[client]);
	ApplyNavMovement(client, iButtons);

	g_iActiveWeapon[client] = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (!IsValidEntity(g_iActiveWeapon[client]))
		return Plugin_Continue;

	g_iTarget[client] = BotGetEnemy(client);
	if (g_bIsProBot[client])
		SelectBestTargetPos(client, g_fTargetPos[client]);
	else
		SelectIntermediateTargetPos(client, g_fTargetPos[client]);

	bool bIsEnemyVisible = !!GetEntData(client, g_iEnemyVisibleOffset);
	if (bIsEnemyVisible && GetEntityMoveType(client) != MOVETYPE_LADDER)
	{
		HandleCombatAimAndMovement(client, iButtons, fVel, fAngles);
		return Plugin_Changed;
	}

	g_iPrevTarget[client] = g_iTarget[client];
	return Plugin_Continue;
}

void ApplyNavMovement(int client, int &iButtons)
{
	g_pCurrArea[client] = NavMesh_GetNearestArea(g_fBotOrigin[client]);
	if (g_pCurrArea[client] == INVALID_NAV_AREA)
		return;

	if (g_pCurrArea[client].Attributes & NAV_MESH_WALK)
		iButtons |= IN_SPEED;

	if (g_pCurrArea[client].Attributes & NAV_MESH_RUN)
		iButtons &= ~IN_SPEED;
}

void HandleCombatAimAndMovement(int client, int &iButtons, float fVel[3], float fAngles[3])
{
	if (!IsValidClient(g_iTarget[client]) || !IsPlayerAlive(g_iTarget[client]) || g_fTargetPos[client][2] == 0.0)
	{
		g_iPrevTarget[client] = g_iTarget[client];
		return;
	}

	if (g_iPrevTarget[client] == -1)
		g_fCrouchTimestamp[client] = GetGameTime() + GetRandomFloat(0.23, 0.25);

	int iDefIndex = GetEntProp(g_iActiveWeapon[client], Prop_Send, "m_iItemDefinitionIndex");
	float fTargetDistance = GetVectorDistance(g_fBotOrigin[client], g_fTargetPos[client]);
	bool bIsDucking = !!(GetEntityFlags(client) & FL_DUCKING);
	bool bIsReloading = IsPlayerReloading(client);
	bool bIsHiding = BotIsHiding(client);
	bool bResumeZoom = !!GetEntProp(client, Prop_Send, "m_bResumeZoom");

	if (bResumeZoom)
		g_fShootTimestamp[client] = GetGameTime();

	float fClientEyes[3], fClientAngles[3], fAimPunchAngle[3], fToAimSpot[3], fAimDir[3];
	GetClientEyePosition(client, fClientEyes);
	SubtractVectors(g_fTargetPos[client], fClientEyes, fToAimSpot);
	GetClientEyeAngles(client, fClientAngles);
	GetEntPropVector(client, Prop_Send, "m_aimPunchAngle", fAimPunchAngle);
	ScaleVector(fAimPunchAngle, FindConVar("weapon_recoil_scale").FloatValue);
	AddVectors(fClientAngles, fAimPunchAngle, fClientAngles);
	GetViewVector(fClientAngles, fAimDir);

	float fRangeToEnemy = NormalizeVector(fToAimSpot, fToAimSpot);
	float fOnTarget = GetVectorDotProduct(fToAimSpot, fAimDir);
	float fAimTolerance = Cosine(ArcTangent(32.0 / fRangeToEnemy));

	if (g_iPrevTarget[client] == -1 && fOnTarget > fAimTolerance)
		g_fCrouchTimestamp[client] = GetGameTime() + GetRandomFloat(0.23, 0.25);

	switch (iDefIndex)
	{
		case 7, 8, 10, 13, 14, 16, 17, 19, 23, 24, 25, 26, 28, 33, 34, 39, 60:
		{
			if (fOnTarget > fAimTolerance && !bIsDucking && fTargetDistance < 2000.0 && !IsRunAndGunWeapon(iDefIndex))
				AutoStop(client, fVel, fAngles);
			else if (fTargetDistance > 2000.0 && GetEntDataFloat(client, g_iFireWeaponOffset) == GetGameTime())
				AutoStop(client, fVel, fAngles);

			if (fOnTarget > fAimTolerance && fTargetDistance < 2000.0)
			{
				iButtons &= ~IN_ATTACK;

				if (!bIsReloading && (GetClientSpeed2D(client) < 50.0 || bIsDucking || IsRunAndGunWeapon(iDefIndex)))
				{
					iButtons |= IN_ATTACK;
					SetEntDataFloat(client, g_iFireWeaponOffset, GetGameTime());
				}
			}
		}
		case 1:
		{
			if (GetGameTime() - GetEntDataFloat(client, g_iFireWeaponOffset) < 0.15 && !bIsDucking && !bIsReloading)
				AutoStop(client, fVel, fAngles);
		}
		case 9, 40:
		{
			if (fTargetDistance < 2750.0 && !bIsReloading && GetEntProp(client, Prop_Send, "m_bIsScoped") && GetGameTime() - g_fShootTimestamp[client] > 0.4 && GetClientAimTarget(client, true) == g_iTarget[client])
			{
				iButtons |= IN_ATTACK;
				SetEntDataFloat(client, g_iFireWeaponOffset, GetGameTime());
			}
		}
	}

	float fClientLoc[3];
	fClientLoc[0] = g_fBotOrigin[client][0];
	fClientLoc[1] = g_fBotOrigin[client][1];
	fClientLoc[2] = g_fBotOrigin[client][2] + 36.0;

	if (GetGameTime() >= g_fCrouchTimestamp[client] && !bIsReloading && IsPointVisible(fClientLoc, g_fTargetPos[client]) && fOnTarget > fAimTolerance && fTargetDistance < 2000.0 && IsCrouchRifle(iDefIndex))
		iButtons |= IN_DUCK;

	if (bIsHiding && g_bUncrouch[client])
		iButtons &= ~IN_DUCK;

	g_iPrevTarget[client] = g_iTarget[client];
}

public MRESReturn BotCOS(DHookReturn hReturn)
{
	hReturn.Value = 0;
	return MRES_Supercede;
}

public MRESReturn BotSIN(DHookReturn hReturn)
{
	hReturn.Value = 0;
	return MRES_Supercede;
}

public MRESReturn CCSBot_GetPartPosition(DHookReturn hReturn, DHookParam hParams)
{
	int iPlayer = hParams.Get(1);
	int iPart = hParams.Get(2);

	if (iPart != 2)
		return MRES_Ignored;

	int iBone = LookupBone(iPlayer, "head_0");
	if (iBone < 0)
		return MRES_Ignored;

	float fHead[3], fBad[3];
	GetBonePosition(iPlayer, iBone, fHead, fBad);
	fHead[2] += 4.0;

	hReturn.SetVector(fHead);
	return MRES_Override;
}

public MRESReturn CCSBot_SetLookAt(int client, DHookParam hParams)
{
	char szDesc[64];
	DHookGetParamString(hParams, 1, szDesc, sizeof(szDesc));

	if (strcmp(szDesc, "Defuse bomb") == 0 || strcmp(szDesc, "Use entity") == 0 || strcmp(szDesc, "Open door") == 0 || strcmp(szDesc, "Hostage") == 0)
		return MRES_Ignored;

	if (strcmp(szDesc, "Avoid Flashbang") == 0)
	{
		DHookSetParam(hParams, 3, PRIORITY_HIGH);
		return MRES_ChangedHandled;
	}

	if (strcmp(szDesc, "Blind") == 0 || strcmp(szDesc, "Face outward") == 0)
		return MRES_Supercede;

	float fPos[3];
	DHookGetParamVector(hParams, 2, fPos);
	fPos[2] += 25.0;
	DHookSetParamVector(hParams, 2, fPos);

	return MRES_ChangedHandled;
}

public MRESReturn CCSBot_PickNewAimSpot(int client, DHookParam hParams)
{
	if (!IsValidClient(client) || (!g_bIsProBot[client] && !g_bIsIntermediateBot[client]) || GetDisposition(client) == IGNORE_ENEMIES)
		return MRES_Ignored;

	g_iTarget[client] = BotGetEnemy(client);

	if (g_bIsProBot[client])
		SelectBestTargetPos(client, g_fTargetPos[client]);
	else
		SelectIntermediateTargetPos(client, g_fTargetPos[client]);

	if (!IsValidClient(g_iTarget[client]) || !IsPlayerAlive(g_iTarget[client]) || g_fTargetPos[client][2] == 0.0)
		return MRES_Ignored;

	SetEntDataVector(client, g_iBotTargetSpotOffset, g_fTargetPos[client]);
	return MRES_Ignored;
}

public void SelectBestTargetPos(int client, float fTargetPos[3])
{
	if (!IsValidClient(g_iTarget[client]) || !IsPlayerAlive(g_iTarget[client]))
		return;

	int iBone = LookupBone(g_iTarget[client], "head_0");
	int iSpineBone = LookupBone(g_iTarget[client], "spine_3");
	if (iBone < 0 || iSpineBone < 0)
		return;

	bool bShootSpine = false;
	float fHead[3], fBody[3], fBad[3];
	GetBonePosition(g_iTarget[client], iBone, fHead, fBad);
	GetBonePosition(g_iTarget[client], iSpineBone, fBody, fBad);

	fHead[2] += 4.0;

	if (BotIsVisible(client, fHead, false, -1))
	{
		if (BotIsVisible(client, fBody, false, -1))
		{
			if (!IsValidEntity(g_iActiveWeapon[client]))
				return;

			int iDefIndex = GetEntProp(g_iActiveWeapon[client], Prop_Send, "m_iItemDefinitionIndex");
			switch (iDefIndex)
			{
				case 7, 8, 10, 13, 14, 16, 17, 19, 23, 24, 25, 26, 27, 28, 29, 33, 34, 35, 39, 60:
				{
					float fTargetDistance = GetVectorDistance(g_fBotOrigin[client], fHead);
					if (IsItMyChance(70.0) && fTargetDistance < 2000.0)
						bShootSpine = true;
				}
				case 9, 11, 38:
				{
					bShootSpine = true;
				}
			}
		}
	}
	else
	{
		for (int b = 0; b < sizeof(g_szBoneNames); b++)
		{
			iBone = LookupBone(g_iTarget[client], g_szBoneNames[b]);
			if (iBone < 0)
				return;

			GetBonePosition(g_iTarget[client], iBone, fHead, fBad);
			if (BotIsVisible(client, fHead, false, -1))
				break;

			fHead[2] = 0.0;
		}
	}

	if (bShootSpine)
		fTargetPos = fBody;
	else
		fTargetPos = fHead;
}

public void SelectIntermediateTargetPos(int client, float fTargetPos[3])
{
	if (!IsValidClient(g_iTarget[client]) || !IsPlayerAlive(g_iTarget[client]))
		return;

	int iBoneHead = LookupBone(g_iTarget[client], "head_0");
	int iBoneSpine = LookupBone(g_iTarget[client], "spine_3");
	if (iBoneHead < 0 || iBoneSpine < 0)
		return;

	float fHead[3], fBody[3], fBad[3];
	GetBonePosition(g_iTarget[client], iBoneHead, fHead, fBad);
	GetBonePosition(g_iTarget[client], iBoneSpine, fBody, fBad);

	fHead[2] += GetRandomFloat(1.0, 3.0);

	bool bVisibleHead = BotIsVisible(client, fHead, false, -1);
	bool bVisibleBody = BotIsVisible(client, fBody, false, -1);
	bool bShootSpine = false;

	if (bVisibleHead || bVisibleBody)
	{
		if (bVisibleHead && IsItMyChance(25.0))
			fTargetPos = fHead;
		else
			bShootSpine = true;
	}
	else
	{
		for (int b = 0; b < sizeof(g_szBoneNames); b++)
		{
			int iBone = LookupBone(g_iTarget[client], g_szBoneNames[b]);
			if (iBone < 0)
				continue;

			float fAlt[3];
			GetBonePosition(g_iTarget[client], iBone, fAlt, fBad);
			if (BotIsVisible(client, fAlt, false, -1))
			{
				fTargetPos = fAlt;
				break;
			}
		}
	}

	if (bShootSpine)
		fTargetPos = fBody;

	float offset[3];
	offset[0] = GetRandomFloat(-2.5, 2.5);
	offset[1] = GetRandomFloat(-2.5, 2.5);
	offset[2] = GetRandomFloat(-1.0, 2.0);
	AddVectors(fTargetPos, offset, fTargetPos);
}

public void AutoStop(int client, float fVel[3], float fAngles[3])
{
	float fPlayerVelocity[3], fVelAngle[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", fPlayerVelocity);
	GetVectorAngles(fPlayerVelocity, fVelAngle);
	float fSpeed = GetVectorLength(fPlayerVelocity);

	if (fSpeed < 1.0)
		return;

	fVelAngle[1] = fAngles[1] - fVelAngle[1];

	float fNegatedDirection[3], fForwardDirection[3];
	GetAngleVectors(fVelAngle, fForwardDirection, NULL_VECTOR, NULL_VECTOR);

	fNegatedDirection[0] = fForwardDirection[0] * (-fSpeed);
	fNegatedDirection[1] = fForwardDirection[1] * (-fSpeed);
	fNegatedDirection[2] = fForwardDirection[2] * (-fSpeed);

	fVel[0] = fNegatedDirection[0];
	fVel[1] = fNegatedDirection[1];
}

public void BotMoveTo(int client, float fOrigin[3], RouteType routeType)
{
	SDKCall(g_hBotMoveTo, client, fOrigin, routeType);
}

public int LookupBone(int iEntity, const char[] szName)
{
	return SDKCall(g_hLookupBone, iEntity, szName);
}

public void GetBonePosition(int iEntity, int iBone, float fOrigin[3], float fAngles[3])
{
	SDKCall(g_hGetBonePosition, iEntity, iBone, fOrigin, fAngles);
}

bool BotIsVisible(int client, float fPos[3], bool bTestFOV, int iIgnore = -1)
{
	return SDKCall(g_hBotIsVisible, client, fPos, bTestFOV, iIgnore);
}

public bool BotIsHiding(int client)
{
	return SDKCall(g_hBotIsHiding, client);
}

public void BotEquipBestWeapon(int client, bool bMustEquip)
{
	SDKCall(g_hBotEquipBestWeapon, client, bMustEquip);
}

public void BotSetLookAt(int client, const char[] szDesc, const float fPos[3], PriorityType pri, float fDuration, bool bClearIfClose, float fAngleTolerance, bool bAttack)
{
	SDKCall(g_hBotSetLookAt, client, szDesc, fPos, pri, fDuration, bClearIfClose, fAngleTolerance, bAttack);
}

public int BotGetEnemy(int client)
{
	return GetEntDataEnt2(client, g_iBotEnemyOffset);
}

stock DispositionType GetDisposition(int client)
{
	return view_as<DispositionType>(GetEntData(client, g_iBotDispositionOffset));
}

void LoadSDK()
{
	GameData hGameConfig = new GameData("botstuff.games");
	if (hGameConfig == null)
		SetFailState("Failed to find botstuff.games game config.");

	if ((g_iBotTargetSpotOffset = hGameConfig.GetOffset("CCSBot::m_targetSpot")) == -1)
		SetFailState("Failed to get CCSBot::m_targetSpot offset.");

	if ((g_iFireWeaponOffset = hGameConfig.GetOffset("CCSBot::m_fireWeaponTimestamp")) == -1)
		SetFailState("Failed to get CCSBot::m_fireWeaponTimestamp offset.");

	if ((g_iEnemyVisibleOffset = hGameConfig.GetOffset("CCSBot::m_isEnemyVisible")) == -1)
		SetFailState("Failed to get CCSBot::m_isEnemyVisible offset.");

	if ((g_iBotEnemyOffset = hGameConfig.GetOffset("CCSBot::m_enemy")) == -1)
		SetFailState("Failed to get CCSBot::m_enemy offset.");

	if ((g_iBotDispositionOffset = hGameConfig.GetOffset("CCSBot::m_disposition")) == -1)
		SetFailState("Failed to get CCSBot::m_disposition offset.");

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CCSBot::MoveTo");
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	if ((g_hBotMoveTo = EndPrepSDKCall()) == null)
		SetFailState("Failed to create SDKCall for CCSBot::MoveTo signature!");

	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CBaseAnimating::LookupBone");
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	if ((g_hLookupBone = EndPrepSDKCall()) == null)
		SetFailState("Failed to create SDKCall for CBaseAnimating::LookupBone signature!");

	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CBaseAnimating::GetBonePosition");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef, _, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef, _, VENCODE_FLAG_COPYBACK);
	if ((g_hGetBonePosition = EndPrepSDKCall()) == null)
		SetFailState("Failed to create SDKCall for CBaseAnimating::GetBonePosition signature!");

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CCSBot::IsVisible");
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	if ((g_hBotIsVisible = EndPrepSDKCall()) == null)
		SetFailState("Failed to create SDKCall for CCSBot::IsVisible signature!");

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CCSBot::IsAtHidingSpot");
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	if ((g_hBotIsHiding = EndPrepSDKCall()) == null)
		SetFailState("Failed to create SDKCall for CCSBot::IsAtHidingSpot signature!");

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CCSBot::EquipBestWeapon");
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
	if ((g_hBotEquipBestWeapon = EndPrepSDKCall()) == null)
		SetFailState("Failed to create SDKCall for CCSBot::EquipBestWeapon signature!");

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConfig, SDKConf_Signature, "CCSBot::SetLookAt");
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
	if ((g_hBotSetLookAt = EndPrepSDKCall()) == null)
		SetFailState("Failed to create SDKCall for CCSBot::SetLookAt signature!");

	delete hGameConfig;
}

void LoadDetours()
{
	GameData hGameData = new GameData("botstuff.games");
	if (hGameData == null)
	{
		SetFailState("Failed to load botstuff gamedata.");
		return;
	}

	DynamicDetour hBotSetLookAtDetour = DynamicDetour.FromConf(hGameData, "CCSBot::SetLookAt");
	if (!hBotSetLookAtDetour.Enable(Hook_Pre, CCSBot_SetLookAt))
		SetFailState("Failed to setup detour for CCSBot::SetLookAt");

	DynamicDetour hBotPickNewAimSpotDetour = DynamicDetour.FromConf(hGameData, "CCSBot::PickNewAimSpot");
	if (!hBotPickNewAimSpotDetour.Enable(Hook_Post, CCSBot_PickNewAimSpot))
		SetFailState("Failed to setup detour for CCSBot::PickNewAimSpot");

	DynamicDetour hBotCOSDetour = DynamicDetour.FromConf(hGameData, "BotCOS");
	if (!hBotCOSDetour.Enable(Hook_Pre, BotCOS))
		SetFailState("Failed to setup detour for BotCOS");

	DynamicDetour hBotSINDetour = DynamicDetour.FromConf(hGameData, "BotSIN");
	if (!hBotSINDetour.Enable(Hook_Pre, BotSIN))
		SetFailState("Failed to setup detour for BotSIN");

	DynamicDetour hBotGetPartPosDetour = DynamicDetour.FromConf(hGameData, "CCSBot::GetPartPosition");
	if (!hBotGetPartPosDetour.Enable(Hook_Pre, CCSBot_GetPartPosition))
		SetFailState("Failed to setup detour for CCSBot::GetPartPosition");

	delete hGameData;
}

void LoadBotTemplates()
{
	g_hBotTemplates.Clear();

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/bot_templates.json");
	if (!FileExists(sPath))
	{
		PrintToServer("[betterbotsplusDM] bot_templates.json not found at %s; unlisted bots will use intermediate aim.", sPath);
		return;
	}

	File hFile = OpenFile(sPath, "r");
	if (hFile == null)
	{
		PrintToServer("[betterbotsplusDM] Could not open bot_templates.json.");
		return;
	}

	char buffer[4096], botName[64], templateName[64];
	while (!IsEndOfFile(hFile) && ReadFileLine(hFile, buffer, sizeof(buffer)))
	{
		if (StrContains(buffer, ":") == -1)
			continue;

		TrimString(buffer);
		ReplaceString(buffer, sizeof(buffer), "\"", "");
		ReplaceString(buffer, sizeof(buffer), ",", "");

		char parts[2][128];
		ExplodeString(buffer, ":", parts, sizeof(parts), sizeof(parts[]));

		TrimString(parts[0]);
		TrimString(parts[1]);

		strcopy(botName, sizeof(botName), parts[0]);
		strcopy(templateName, sizeof(templateName), parts[1]);
		g_hBotTemplates.SetString(botName, templateName);
	}

	delete hFile;
	PrintToServer("[betterbotsplusDM] Loaded bot_templates.json (%d entries).", g_hBotTemplates.Size);
}

void ClassifyBot(int client)
{
	if (!IsValidClient(client) || !IsFakeClient(client))
		return;

	char szBotName[MAX_NAME_LENGTH];
	GetClientName(client, szBotName, sizeof(szBotName));

	char sTemplate[MAX_TEMPLATE_NAME];
	if (g_hBotTemplates.GetString(szBotName, sTemplate, sizeof(sTemplate)))
	{
		g_bIsProBot[client] = IsProTemplate(sTemplate);
		g_bIsIntermediateBot[client] = !g_bIsProBot[client];
	}
	else
	{
		g_bIsProBot[client] = false;
		g_bIsIntermediateBot[client] = true;
	}

	g_iTarget[client] = -1;
	g_iPrevTarget[client] = -1;
}

stock void SetPlayerTeammateColor(int client)
{
	if (!IsValidClient(client) || GetClientTeam(client) <= CS_TEAM_SPECTATOR)
		return;

	if (g_iPlayerColor[client] > -1)
		return;

	int nAssignedColor;
	bool bColorInUse = false;
	for (int ii = 0; ii < 5; ii++)
	{
		nAssignedColor = nAssignedColor % 5;
		bColorInUse = false;

		for (int j = 1; j <= MaxClients; j++)
		{
			if (!IsValidClient(j) || GetClientTeam(j) != GetClientTeam(client))
				continue;

			if (nAssignedColor == g_iPlayerColor[j] && j != client)
			{
				bColorInUse = true;
				nAssignedColor++;
				break;
			}
		}

		if (!bColorInUse)
			break;
	}

	g_iPlayerColor[client] = !bColorInUse ? nAssignedColor : -1;
}

bool IsProTemplate(const char[] sTemplate)
{
	return StrEqual(sTemplate, "Star", false) ||
		StrEqual(sTemplate, "Fragger", false) ||
		StrEqual(sTemplate, "Solid", false) ||
		StrEqual(sTemplate, "Medium", false) ||
		StrEqual(sTemplate, "Avg", false) ||
		StrEqual(sTemplate, "Low", false) ||
		StrEqual(sTemplate, "Bad", false);
}

bool IsRunAndGunWeapon(int iDefIndex)
{
	return iDefIndex == 17 || iDefIndex == 19 || iDefIndex == 23 || iDefIndex == 24 || iDefIndex == 25 || iDefIndex == 26 || iDefIndex == 33 || iDefIndex == 34;
}

bool IsCrouchRifle(int iDefIndex)
{
	return iDefIndex == 7 || iDefIndex == 8 || iDefIndex == 10 || iDefIndex == 13 || iDefIndex == 14 || iDefIndex == 16 || iDefIndex == 28 || iDefIndex == 39 || iDefIndex == 60;
}

float GetClientSpeed2D(int client)
{
	float fPlayerVelocity[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", fPlayerVelocity);
	fPlayerVelocity[2] = 0.0;
	return GetVectorLength(fPlayerVelocity);
}

bool IsPlayerReloading(int client)
{
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon == -1 || !IsValidEntity(weapon))
		return false;

	return !!GetEntProp(weapon, Prop_Data, "m_bInReload");
}

void GetViewVector(float fVecAngle[3], float fOutPut[3])
{
	fOutPut[0] = Cosine(DegToRad(fVecAngle[1])) * Cosine(DegToRad(fVecAngle[0]));
	fOutPut[1] = Sine(DegToRad(fVecAngle[1])) * Cosine(DegToRad(fVecAngle[0]));
	fOutPut[2] = -Sine(DegToRad(fVecAngle[0]));
}

stock bool IsPointVisible(float fStart[3], float fEnd[3])
{
	TR_TraceRayFilter(fStart, fEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceEntityFilterStuff);
	return TR_GetFraction() == 1.0;
}

public bool TraceEntityFilterStuff(int iEntity, int iMask)
{
	return iEntity > MaxClients || !iEntity;
}

stock bool IsItMyChance(float fChance = 0.0)
{
	if (fChance <= 0.0)
		return false;

	return GetRandomFloat(0.0, 100.0) <= fChance;
}

stock bool IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client) && !IsClientSourceTV(client);
}
