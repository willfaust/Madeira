#!/usr/bin/env python3
"""Compile the actual bridge environment block: Steam gets no game identity."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'app/Madeira/WineProcessBridge.m').read_text()
a=s.index('        const char *native_launch = getenv("MADEIRA_NATIVE_STEAM_LAUNCH");')
b=s.index('        unsetenv("MADEIRA_STEAM_APPPATH");',a)+len('        unsetenv("MADEIRA_STEAM_APPPATH");')
block=s[a:b]
code=r'''
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "steam_client_identity.h"
static void apply(void) { BLOCK }
static void seed(const char *image) {
 unsetenv("MADEIRA_DOCK_SESSION");
 unsetenv("MADEIRA_NATIVE_STEAM_LAUNCH");
 unsetenv("MADEIRA_ARGS");
 setenv("MADEIRA_EXE",image,1);
 setenv("SteamAppId","356400",1);setenv("SteamGameId","356400",1);
 setenv("SteamAppPath","C:\\Program Files\\Thumper",1);
 setenv("MADEIRA_STEAM_APPID","730",1);setenv("MADEIRA_STEAM_APPPATH","C:\\Games\\CS2",1);
}
static void empty(void) {
 assert(!getenv("SteamAppId") && !getenv("SteamGameId") && !getenv("SteamAppPath"));
 assert(!getenv("MADEIRA_STEAM_APPID") && !getenv("MADEIRA_STEAM_APPPATH"));
 assert(!getenv("MADEIRA_NATIVE_STEAM_LAUNCH"));
}
int main(void) {
 const char *clients[]={"steam.exe","STEAM.EXE","C:\\Program Files (x86)\\Steam\\steam.exe","C:/Steam/Steam.Exe"};
 for(unsigned i=0;i<sizeof(clients)/sizeof(clients[0]);i++) { seed(clients[i]);apply();empty(); }
 assert(!madeira_is_steam_client_image(NULL));
 assert(!madeira_is_steam_client_image("C:\\Steam\\game.exe"));
 assert(!madeira_is_steam_client_image("C:\\game\\notsteam.exe"));
 assert(!madeira_is_steam_client_image("steam.exe.extra"));
 assert(!madeira_is_steam_client_image("C:\\Steam\\steamwebhelper.exe"));
 const char *wrappers[]={"C:\\windows\\system32\\cmd.exe","explorer.exe"};
 const char *launches[]={"/c C:\\madeira-native-steam.cmd","/desktop=shell,1280x720 cmd /c C:\\steam-launch.bat"};
 for(unsigned i=0;i<sizeof(wrappers)/sizeof(wrappers[0]);i++) {
  seed(wrappers[i]);setenv("MADEIRA_ARGS",launches[i],1);setenv("MADEIRA_NATIVE_STEAM_LAUNCH","1",1);
  apply();empty();assert(!getenv("MADEIRA_DOCK_SESSION"));
 }
 seed("dockhost.exe");setenv("MADEIRA_DOCK_SESSION","1",1);apply();empty();
 seed("C:\\Games\\game.exe");apply();
 assert(!strcmp(getenv("SteamAppId"),"730") && !strcmp(getenv("SteamAppPath"),"C:\\Games\\CS2"));
 seed("explorer.exe");unsetenv("MADEIRA_STEAM_APPID");unsetenv("MADEIRA_STEAM_APPPATH");apply();
 assert(!strcmp(getenv("SteamAppId"),"356400")); /* preserve existing unrelated-launch behavior */
 seed("C:\\windows\\system32\\cmd.exe");unsetenv("MADEIRA_STEAM_APPID");unsetenv("MADEIRA_STEAM_APPPATH");
 setenv("MADEIRA_ARGS","/c C:\\Games\\game.cmd",1);apply();
 assert(!strcmp(getenv("SteamAppId"),"356400") && !strcmp(getenv("SteamAppPath"),"C:\\Program Files\\Thumper"));
 seed("cmd.exe");setenv("MADEIRA_NATIVE_STEAM_LAUNCH","0",1);apply();
 assert(!strcmp(getenv("SteamAppId"),"730") && !getenv("MADEIRA_NATIVE_STEAM_LAUNCH"));
 /* A consumed signal cannot clear the next ordinary launch's identity. */
 setenv("MADEIRA_EXE","cmd.exe",1);apply();assert(!strcmp(getenv("SteamAppId"),"356400"));
 puts("PASS Steam images/generated wrappers clear stale identity before Wine snapshot and consume their signal; ordinary cmd, Dock and explicit game identities preserved");
}
'''.replace('BLOCK',block)
with tempfile.TemporaryDirectory() as d:
 c,e=Path(d)/'env.c',Path(d)/'env';c.write_text(code)
 subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-I'+str(root/'app/Madeira'),str(c),'-o',str(e)],check=True)
 subprocess.run([str(e)],check=True)
content=(root/'app/Madeira/ContentView.swift').read_text()
assert content.count('nativeSteamClient: true')==2
assert 'runWineFullSequence(nativeSteamClient: true)' in content
assert 'startLibraryEntry(launch, remember: false, preferences: entry, nativeSteamClient: true)' in content
assert 'runWineFullSequence(profile: effectiveProfile, nativeSteamClient: nativeSteamClient)' in content
worker=content[content.index('private func runWineFullSequence('):content.index('private func startWineProcess(')]
assert worker.index('profile.applyEnvironment()') < worker.index('self.startWineProcess(nativeSteamClient: nativeSteamClient)')
launch=content[content.index('private func startWineProcess('):content.index('private func testDualMapping(')]
assert launch.index('setenv("MADEIRA_NATIVE_STEAM_LAUNCH", "1", 1)') < launch.index('wine_process_start(winePrefixPath)')
assert 'else { unsetenv("MADEIRA_NATIVE_STEAM_LAUNCH") }' in launch
assert 'if nativeSteamClient || image.contains("steam.exe")' in launch
