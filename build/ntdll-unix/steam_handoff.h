/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Embedded Windows process liveness. No Wine/server call runs under this lock.
 * Steam clients, not their helpers, hold a native Steam session open. */
#ifndef MADEIRA_STEAM_HANDOFF_H
#define MADEIRA_STEAM_HANDOFF_H
#define IOS_CHILD_SLOTS 32
#define IOS_STEAM_PATH_UNITS 1024
struct ios_child_token { int slot; unsigned long long generation; };
static pthread_mutex_t ios_child_lock = PTHREAD_MUTEX_INITIALIZER;
static struct ios_child_record
{
    char name[64];
    double started;
    unsigned pid, parent_pid, anchor;
    void *owner, *parent_owner;
    unsigned long long generation;
    int used, steam, wrapper;
} ios_child_slots[IOS_CHILD_SLOTS];
static unsigned long long ios_child_generation;
static unsigned ios_steam_reports;
static struct
{
    int enabled, root_steam, root_alive, path_length, last_valid;
    unsigned root_pid, leader, focus_from, last_pid;
    void *root_owner;
    int last_status;
    unsigned long long focus_epoch, focus_pending;
    WCHAR path[IOS_STEAM_PATH_UNITS];
} ios_steam_session;
static _Thread_local struct ios_child_token ios_current_child = { -1, 0 };

static double ios_child_now(void)
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int ios_child_is_helper( const char *name )
{
    static const char *const parts[] = { "crash", "crs-handler", "handler", "report", "helper" };
    unsigned i;
    for (i = 0; i < ARRAY_SIZE(parts); i++) if (strstr( name, parts[i] )) return 1;
    return 0;
}

static WCHAR ios_steam_path_char( WCHAR c )
{
    if (c == '/') c = '\\';
    return c >= 'A' && c <= 'Z' ? c + 'a' - 'A' : c;
}

static int ios_child_image_is( const UNICODE_STRING *image, const char *name )
{
    unsigned i, start = 0, len;
    if (!image) return 0;
    len = image->Length / sizeof(WCHAR);
    for (i = 0; i < len; i++) if (image->Buffer[i] == '\\' || image->Buffer[i] == '/') start = i+1;
    for (i = start; i < len; i++)
        if (!*name || ios_steam_path_char(image->Buffer[i]) != (unsigned char)*name++) return 0;
    return !*name;
}

static int ios_steam_path_match( const UNICODE_STRING *image, int establish )
{
    unsigned n = image->Length / sizeof(WCHAR), start = 0, i;
    /* The loader can supply the NT spelling of the same DOS image. */
    if (n >= 4 && image->Buffer[0] == '\\' && image->Buffer[1] == '?' &&
        image->Buffer[2] == '?' && image->Buffer[3] == '\\') start = 4;
    n -= start;
    if (!n || n >= IOS_STEAM_PATH_UNITS) return 0;
    if (!ios_steam_session.path_length && establish)
    {
        for (i = 0; i < n; i++) ios_steam_session.path[i] = ios_steam_path_char(image->Buffer[start+i]);
        ios_steam_session.path_length = n;
    }
    if ((unsigned)ios_steam_session.path_length != n) return 0;
    for (i = 0; i < n; i++)
        if (ios_steam_session.path[i] != ios_steam_path_char(image->Buffer[start+i])) return 0;
    return 1;
}

static void ios_steam_choose_leader_locked( unsigned previous )
{
    unsigned leader = 0, i;
    unsigned long long newest = 0;
    if (ios_steam_session.root_steam && ios_steam_session.root_alive) leader = ios_steam_session.root_pid;
    if (!leader)
        for (i = 0; i < IOS_CHILD_SLOTS; i++)
            if (ios_child_slots[i].used && ios_child_slots[i].steam && ios_child_slots[i].generation > newest)
            { leader = ios_child_slots[i].pid; newest = ios_child_slots[i].generation; }
    ios_steam_session.leader = leader;
    if (leader && leader != previous)
    {
        ios_steam_session.focus_from = previous;
        if (!++ios_steam_session.focus_epoch) ++ios_steam_session.focus_epoch;
        ios_steam_session.focus_pending = ios_steam_session.focus_epoch;
    }
    else if (!leader) ios_steam_session.focus_pending = 0;
}

void madeira_child_session_begin( int native_steam, int root_steam )
{
    pthread_mutex_lock( &ios_child_lock );
    memset( ios_child_slots, 0, sizeof(ios_child_slots) );
    memset( &ios_steam_session, 0, sizeof(ios_steam_session) );
    ios_steam_session.enabled = native_steam;
    ios_steam_session.root_steam = root_steam;
    ios_steam_session.root_alive = 1;
    __atomic_store_n(&ios_steam_reports,0,__ATOMIC_RELAXED);
    pthread_mutex_unlock( &ios_child_lock );
}

static struct ios_child_token ios_child_slot_take( const UNICODE_STRING *image, unsigned pid,
        unsigned parent_pid, void *parent_owner, void *session_owner, const UNICODE_STRING *parent_image )
{
    struct ios_child_token token = { -1, 0 };
    char name[64];
    unsigned i, n = 0, start = 0, len = image->Length / sizeof(WCHAR), anchor = 0;
    int root_parent = 0, wrapper_parent = 0, trusted = 0;
    for (i = 0; i < len; i++) if (image->Buffer[i] == '\\' || image->Buffer[i] == '/') start = i + 1;
    for (i = start; i < len && n < sizeof(name)-1; i++)
    {
        WCHAR c = image->Buffer[i];
        name[n++] = c >= 'A' && c <= 'Z' ? c + 32 : c >= 32 && c < 127 ? c : '?';
    }
    if (!n) name[n++] = '?';
    name[n] = 0;
    pthread_mutex_lock( &ios_child_lock );
    if (ios_steam_session.enabled)
    {
        if (!ios_steam_session.root_owner && parent_owner && parent_owner == session_owner)
        {
            ios_steam_session.root_owner = parent_owner; ios_steam_session.root_pid = parent_pid;
            if (ios_steam_session.root_steam) ios_steam_session.leader = parent_pid;
        }
        root_parent = ios_steam_session.root_alive && parent_pid == ios_steam_session.root_pid &&
                      parent_owner == ios_steam_session.root_owner;
        /* A directly launched client's actual PEB image pins the restart
         * path. Generated cmd/explorer launchers pin their first Steam child. */
        if (root_parent && ios_steam_session.root_steam && !ios_steam_session.path_length && parent_image)
            ios_steam_path_match(parent_image,1);
        if (root_parent && ios_steam_session.root_steam) anchor = parent_pid;
        if (root_parent && !ios_steam_session.root_steam)
            wrapper_parent = ios_child_image_is(parent_image,"cmd.exe") || ios_child_image_is(parent_image,"explorer.exe");
        for (i = 0; i < IOS_CHILD_SLOTS && !anchor; i++)
            if (ios_child_slots[i].used && ios_child_slots[i].pid == parent_pid &&
                ios_child_slots[i].owner == parent_owner)
            { anchor = ios_child_slots[i].anchor; wrapper_parent |= ios_child_slots[i].wrapper; break; }
        trusted = !strcmp(name,"steam.exe") && (anchor || wrapper_parent) && ios_steam_path_match(image,1);
    }
    for (i = 0; i < IOS_CHILD_SLOTS; i++)
    {
        struct ios_child_record *record = &ios_child_slots[i];
        if (record->used) continue;
        memset( record, 0, sizeof(*record) );
        if (!++ios_child_generation) ++ios_child_generation;
        record->generation = ios_child_generation; record->used = 1;
        record->pid = pid; record->parent_pid = parent_pid; record->parent_owner = parent_owner;
        record->started = ios_child_now(); record->steam = trusted;
        record->wrapper = wrapper_parent && (!strcmp(name,"cmd.exe") || !strcmp(name,"explorer.exe"));
        record->anchor = trusted ? pid : anchor;
        memcpy( record->name, name, n+1 ); token.slot = i; token.generation = record->generation;
        if (trusted && !ios_steam_session.leader) ios_steam_session.leader = pid;
        break;
    }
    pthread_mutex_unlock( &ios_child_lock );
    if (!strcmp(name,"steam.exe") && __atomic_fetch_add(&ios_steam_reports,1,__ATOMIC_RELAXED) < 24)
    {
        int saved_errno = errno;
        dprintf(2,"[steam-handoff-v1] spawn parent=%04x child=%04x trusted=%u generation=%llu tracked=%u\n",
                parent_pid,pid,trusted,token.generation,token.slot >= 0);
        errno = saved_errno;
    }
    return token;
}

static void ios_child_retire_locked( struct ios_child_record *record, int status )
{
    unsigned previous = ios_steam_session.leader;
    if (record->steam && record->pid == previous)
    {
        ios_steam_session.last_valid = 1; ios_steam_session.last_status = status;
        ios_steam_session.last_pid = record->pid;
    }
    record->used = 0;
    if (record->pid == previous) ios_steam_choose_leader_locked(previous);
}

static void ios_child_slot_release( struct ios_child_token token )
{
    if (token.slot < 0 || token.slot >= IOS_CHILD_SLOTS) return;
    pthread_mutex_lock( &ios_child_lock );
    if (ios_child_slots[token.slot].used && ios_child_slots[token.slot].generation == token.generation)
        ios_child_retire_locked( &ios_child_slots[token.slot], 1 );
    pthread_mutex_unlock( &ios_child_lock );
}

void madeira_child_process_started( void *owner, unsigned pid )
{
    struct ios_child_token token = ios_current_child;
    if (token.slot < 0 || token.slot >= IOS_CHILD_SLOTS) return;
    pthread_mutex_lock( &ios_child_lock );
    if (ios_child_slots[token.slot].used && ios_child_slots[token.slot].generation == token.generation &&
        ios_child_slots[token.slot].pid == pid) ios_child_slots[token.slot].owner = owner;
    pthread_mutex_unlock( &ios_child_lock );
}

/* Server last-thread death is authoritative even when a native boot pthread
 * remains alive. Native exit is a fallback for pre-server bootstrap failure. */
static void ios_child_process_exited_locked( unsigned pid, int status )
{
    unsigned i, previous;
    previous = ios_steam_session.leader;
    if (pid == ios_steam_session.root_pid && ios_steam_session.root_alive)
    {
        ios_steam_session.root_alive = 0;
        if (previous == pid)
        {
            ios_steam_session.last_valid = 1; ios_steam_session.last_status = status;
            ios_steam_session.last_pid = pid; ios_steam_choose_leader_locked(previous);
        }
        else if (ios_steam_session.leader && !ios_steam_session.focus_pending)
            ios_steam_choose_leader_locked(0);
    }
    for (i = 0; i < IOS_CHILD_SLOTS; i++)
        if (ios_child_slots[i].used && ios_child_slots[i].pid == pid)
        { ios_child_retire_locked(&ios_child_slots[i],status); break; }
    if (ios_steam_session.last_valid && ios_steam_session.last_pid == pid) ios_steam_session.last_status = status;
}

void madeira_child_server_exited( unsigned pid, int status )
{
    pthread_mutex_lock( &ios_child_lock );
    ios_child_process_exited_locked(pid,status);
    pthread_mutex_unlock( &ios_child_lock );
}

void madeira_child_process_exited( void *owner, unsigned pid, int status )
{
    unsigned i;
    int found = 0;
    pthread_mutex_lock( &ios_child_lock );
    if (ios_steam_session.root_owner == owner && ios_steam_session.root_pid == pid) found = 1;
    for (i = 0; !found && i < IOS_CHILD_SLOTS; i++)
        if (ios_child_slots[i].used && ios_child_slots[i].owner == owner && ios_child_slots[i].pid == pid) found = 1;
    /* Validate ownership and retire under the same lock: a late native
     * cleanup must not retire a replacement occupying a reused slot. */
    if (found) ios_child_process_exited_locked(pid,status);
    pthread_mutex_unlock( &ios_child_lock );
}

void madeira_steam_main_returned( int status )
{
    unsigned pid;
    pthread_mutex_lock( &ios_child_lock ); pid = ios_steam_session.root_pid; pthread_mutex_unlock( &ios_child_lock );
    if (pid) madeira_child_server_exited(pid,status);
}

int madeira_live_game_children( char *buf, int len, double max_age )
{
    double now = ios_child_now();
    int count = 0, used = 0;
    unsigned i;
    if (buf && len > 0) buf[0] = 0;
    pthread_mutex_lock( &ios_child_lock );
    for (i = 0; i < IOS_CHILD_SLOTS; i++)
    {
        if (!ios_child_slots[i].used || ios_child_is_helper(ios_child_slots[i].name)) continue;
        if (max_age >= 0 && now - ios_child_slots[i].started > max_age) continue;
        count++;
        if (buf && len-used > 1) used += snprintf(buf+used,len-used,"%s%s",used?" ":"",ios_child_slots[i].name);
        if (used >= len) used = len-1;
    }
    pthread_mutex_unlock( &ios_child_lock ); return count;
}

int madeira_live_steam_successors( unsigned *leader )
{
    unsigned i;
    int count = 0;
    pthread_mutex_lock( &ios_child_lock );
    if (ios_steam_session.enabled)
        for (i = 0; i < IOS_CHILD_SLOTS; i++) if (ios_child_slots[i].used && ios_child_slots[i].steam) count++;
    if (leader) *leader = ios_steam_session.leader;
    pthread_mutex_unlock( &ios_child_lock ); return count;
}

int madeira_steam_final_status( int fallback )
{
    int status;
    pthread_mutex_lock( &ios_child_lock );
    status = ios_steam_session.last_valid ? ios_steam_session.last_status : fallback;
    pthread_mutex_unlock( &ios_child_lock ); return status;
}

unsigned long long madeira_steam_focus_epoch( unsigned pid )
{
    unsigned i, anchor;
    unsigned long long epoch = 0;
    pthread_mutex_lock( &ios_child_lock );
    anchor = pid == ios_steam_session.root_pid ? pid : 0;
    for (i = 0; i < IOS_CHILD_SLOTS; i++)
        if (ios_child_slots[i].used && ios_child_slots[i].pid == pid)
        { anchor = ios_child_slots[i].steam || ios_child_is_helper(ios_child_slots[i].name) ? ios_child_slots[i].anchor : 0; break; }
    if (ios_steam_session.enabled && anchor && anchor == ios_steam_session.leader) epoch = ios_steam_session.focus_pending;
    pthread_mutex_unlock( &ios_child_lock ); return epoch;
}

int madeira_steam_focus_can_replace( unsigned pid )
{
    unsigned i;
    int allowed;
    pthread_mutex_lock( &ios_child_lock );
    allowed = !pid || pid == ios_steam_session.leader ||
              pid == (ios_steam_session.focus_from ? ios_steam_session.focus_from : ios_steam_session.root_pid);
    for (i = 0; !allowed && i < IOS_CHILD_SLOTS; i++)
        if (ios_child_slots[i].used && ios_child_slots[i].pid == pid &&
            (ios_child_slots[i].steam || ios_child_is_helper(ios_child_slots[i].name)) &&
            ((ios_steam_session.focus_from && ios_child_slots[i].anchor == ios_steam_session.focus_from) ||
             ios_child_slots[i].anchor == ios_steam_session.leader)) allowed = 1;
    pthread_mutex_unlock( &ios_child_lock ); return allowed;
}

void madeira_steam_focus_completed( unsigned pid, unsigned long long epoch )
{
    unsigned i, anchor = 0;
    pthread_mutex_lock( &ios_child_lock );
    for (i = 0; i < IOS_CHILD_SLOTS; i++)
        if (ios_child_slots[i].used && ios_child_slots[i].pid == pid)
        { anchor = ios_child_slots[i].steam || ios_child_is_helper(ios_child_slots[i].name) ? ios_child_slots[i].anchor : 0; break; }
    if (anchor == ios_steam_session.leader && epoch == ios_steam_session.focus_pending) ios_steam_session.focus_pending = 0;
    pthread_mutex_unlock( &ios_child_lock );
}
#endif
