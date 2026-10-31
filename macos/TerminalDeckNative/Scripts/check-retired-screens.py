#!/usr/bin/env python3
"""U155 regression guard. CI: python3 macos/TerminalDeckNative/Scripts/check-retired-screens.py"""
from pathlib import Path
import re

PACKAGE = Path(__file__).resolve().parent.parent
# These were verified unused, then removed together. Reject a restored parallel UI
# implementation, even if a future fixture accidentally gives it a caller.
# ORGCanvasInput is live again: the org chart now mounts it for pan and zoom.
RETIRED = '''NativeTasksScreen NativeChatComposer NativeChatView NativeCopilotRailPanel
GitHubTab IslandWeb IslandRelay NativeIslandChat NativeIslandFeed NativeIslandSessions NativeMemoryScreen NativeStaysFixedScreen
AGTAllAgentsView AGTAgentCard AGTAgentRow AGTListHeader AGTGroupHeader AGTAgentMenu
AGFRAMEFallbackCard AGFRAMEFallbackProjectChip AGFRAMEFallbackAvatar
AGFRAMEFallbackGlassSwitch AGFRAMEFallbackProjectPicker AGFRAMEFallbackPageHost
ROUTINESFallbackAgentAvatar NativeMACHINESFallbackTokens NativeMACHINESFallbackPage
NativeMACHINESFallbackRowStyle NativeMACHINESFallbackGlassSwitch
NativeSettingsFallbackStyle NativeSettingsFallbackRowStyle CopilotSessionGroup
McpServerRow McpMachinePills McpMachineServerList NativeServerOpenTerminal
NativeServerHealth NativeServerCardGroup NativeRCVRailButton NativeRCVContent
NativeRCVFlowPage NativeRCVFlowRow NativeCodingAIAccountsSections
NativeCodingAIDeviceSection NativeCodingAIServersSection NativeCodingAIScopePicker
NativeServersArea NativeTerminalWindowChrome SessionChatUsageButton DeckLoading
NativeHooksOffer ControlOffer PluginsExplain NativeScrapingBody NativeServerFolderLine
NativeBrowserMachinePorts NativeFIXESCommentReceiptView NativeFIXESCommentReceiptAvatar
AGTSidebarCount AGTDeviceRow AGTDeviceHeader AWProjectMark
NativeAppsSRV2ServerSections BackendTaskChangeBus BackendServersSSHFollow
BackendRemoteGuestTunnelReference BackendRemotePanelChannels
BackendRemoteServeTransportChannels BackendRemoteServeWindowGrantChannels
BackendRemoteServeTransportNativePorts BackendRemoteServeAccountLoginAdapter
BackendRemoteHostTailnet BackendMacAppWindowsTools BackendMacAppWindowsNativeMenuHost
BackendMacAppSetupLocalUserDataIO BackendHootRegistrationUnavailableJoins
BackendTaskProviderAnswers BackendDeckToolsSessionsAssembly NativeMcpCatalogPage
NativeMcpCatalogTokens NativeMcpCatalogRowStyle NativeMcpCatalogProjectPicker
NativeMcpCatalogSettingsFrame'''.split()
pattern = re.compile(r'\b(?:struct|class|actor|enum|typealias)\s+(' + '|'.join(RETIRED) + r')\b')
failures = []
for path in (PACKAGE / 'Sources').rglob('*.swift'):
    # Comments can still document old names; only declarations are forbidden.
    source = re.sub(r'//[^\n]*|/\*.*?\*/', '', path.read_text(), flags=re.S)
    failures.extend(f'{path.relative_to(PACKAGE)}: {match[1]}' for match in pattern.finditer(source))
if failures:
    raise SystemExit('\n'.join(failures))
print(f'U155: {len(RETIRED)} retired declarations absent')
