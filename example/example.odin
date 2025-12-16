package steamworks_example

import "base:runtime"
import "core:log"

import steam "../"
import rl "vendor:raylib"

// https://partner.steamgames.com/doc/sdk/api
// https://partner.steamgames.com/doc/sdk/api#manual_dispatch

number_of_current_players: int
g_friends: ^steam.IFriends
g_client: ^steam.IClient

main :: proc() {
    context.logger = log.create_console_logger()

    if steam.RestartAppIfNecessary(steam.uAppIdInvalid) {
        log.debug("Launching app through steam...")
        return
    }

    err_msg: steam.SteamErrMsg
    if err := steam.InitFlat(&err_msg); err != .OK {
        log.debug("steam.InitFlat failed with code '{}' and message \"{}\"", err, cast(cstring)&err_msg[0])
        log.panic("Steam Init failed. Make sure Steam is running.")
    }
    defer steam.Shutdown()

    g_client = steam.Client()
    steam.Client_SetWarningMessageHook(g_client, steam_debug_text_hook)

    steam.ManualDispatch_Init()

    if !steam.User_BLoggedOn(steam.User()) {
        log.panic("User isn't logged in.")
    }
    g_friends = steam.Friends()
    user := string(steam.Friends_GetPersonaName(g_friends))
    state := steam.Friends_GetPersonaState(g_friends)
    log.info("LOGGED IN AS", user, state)

    // lobbyCall := steam.Matchmaking_RequestLobbyList(steam.Matchmaking())

    rl.InitWindow(800, 480, "Odin Steamworks Example")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        rl.BeginDrawing()
        rl.ClearBackground(rl.DARKBLUE)
        defer rl.EndDrawing()
        rl.DrawFPS(2, 2)
        rl.DrawText("Press Shift+Tab to open Steam Overlay", 2, 22 * 2, 20, rl.WHITE)
        rl.DrawText(rl.TextFormat("Friends_GetPersonaName: %s", user), 2, 22 * 4, 20, rl.WHITE)
        rl.DrawText(rl.TextFormat("Friends_GetPersonaState: %s", state), 2, 22 * 5, 20, rl.WHITE)
        rl.DrawText(
            rl.TextFormat("Number of current players (refresh with N key): %i", number_of_current_players),
            2,
            22 * 6,
            20,
            rl.WHITE,
        )
        run_steam_callbacks: {
            // temp_mem := make([dynamic]byte, context.temp_allocator)

            steam_pipe := steam.GetHSteamPipe()
            steam.ManualDispatch_RunFrame(steam_pipe)
            callback: steam.CallbackMsg

            for steam.ManualDispatch_GetNextCallback(steam_pipe, &callback) {
                // Check for dispatching API call results
                if callback.iCallback == .SteamAPICallCompleted {
                    log.debug("CallResult: ", callback)

                    call_completed := cast(^steam.SteamAPICallCompleted)callback.pubParam
                    // resize(&temp_mem, int(callback.cubParam))
                    temp_call_res := make([^]byte, int(callback.cubParam), allocator = context.temp_allocator)
                    bFailed: bool
                    if steam.ManualDispatch_GetAPICallResult(
                        steam_pipe,
                        call_completed.hAsyncCall,
                        &temp_call_res,
                        callback.cubParam,
                        callback.iCallback,
                        &bFailed,
                    ) {
                        // Dispatch the call result to the registered handler(s) for the
                        // call identified by call_completed->m_hAsyncCall
                        log.debug("   call_completed", call_completed)
                        if call_completed.iCallback == .NumberOfCurrentPlayers {
                            using res := cast(^steam.NumberOfCurrentPlayers)temp_call_res

                            log.debug("[get_number_of_current_players] success:", bSuccess)
                            if bFailed || !bool(bSuccess) {
                                log.debug("get_number_of_current_players failed.")
                                return
                            }

                            log.debug("[get_number_of_current_players] Number of players currently playing:", cPlayers)
                            number_of_current_players = int(cPlayers)
                        }
                    }

                } else {
                    // Look at callback.m_iCallback to see what kind of callback it is,
                    // and dispatch to appropriate handler(s)
                    log.debug("ignored Callback: ", callback)

                    if callback.iCallback == .GameOverlayActivated {
                        // log.debug("GameOverlayActivated")
                        using res := cast(^steam.GameOverlayActivated)callback.pubParam
                        log.debug("Is overlay active =", bActive)
                    }
                }

                steam.ManualDispatch_FreeLastCallback(steam_pipe)
            }
        }

        if rl.IsKeyPressed(.N) {
            log.debug("[get_number_of_current_players] Getting number of current players.")
            log.debug("get number of current players:", steam.UserStats_GetNumberOfCurrentPlayers(steam.UserStats()))
        }
    }
}

steam_debug_text_hook :: proc "c" (severity: i32, debugText: cstring) {
    // if you're running in the debugger, only warnings (nSeverity >= 1) will be sent
    // if you add -debug_steamworksapi to the command-line, a lot of extra informational messages will also be sent
    runtime.print_string(string(debugText))

    if severity >= 1 {
        runtime.debug_trap()
    }
}

