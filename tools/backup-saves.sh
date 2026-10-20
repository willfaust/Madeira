#!/bin/sh
set -e

adana="$1"
bursa="$2"
konya="$3"

if [ "$adana" = "-h" ] || [ "$adana" = "--help" ] || [ -z "$adana" ] || [ -z "$bursa" ]; then
    echo "Usage: $0 <backup|restore> <prefix_dir> [archive_file]"
    echo "  backup  : archive saves and user data from prefix"
    echo "  restore : extract save archive back into prefix"
    exit 1
fi

[ -d "$bursa" ] || { echo "error: prefix directory not found: $bursa" >&2; exit 1; }

izmir="${konya:-saves-backup.tar.gz}"

case "$adana" in
    backup)
        echo "backing up saves from $bursa to $izmir..."
        tar -czf "$izmir" -C "$bursa" \
            --exclude='drive_c/users/*/AppData/Local/Temp' \
            drive_c/users/*/Saved\ Games \
            drive_c/users/*/Documents \
            drive_c/users/*/AppData/Local \
            drive_c/users/*/AppData/Roaming \
            user.reg 2>/dev/null || tar -czf "$izmir" -C "$bursa" drive_c/users user.reg 2>/dev/null || true
        echo "backup written to $izmir"
        ;;
    restore)
        [ -f "$izmir" ] || { echo "error: archive file not found: $izmir" >&2; exit 1; }
        echo "restoring saves from $izmir to $bursa..."
        tar -xzf "$izmir" -C "$bursa"
        echo "restore finished"
        ;;
    *)
        echo "error: unknown action: $adana (expected backup or restore)" >&2
        exit 1
        ;;
esac
