
# ---------------------------------------------------------------------------
# embedded core sources
#
# build.sh drops the contents of core/*.go in here. Shipping the source rather
# than a binary means one file works on amd64 and arm64 alike, and there is
# never a release download to be blocked.
# ---------------------------------------------------------------------------

write_core_sources() {
    local d="$1"
    mkdir -p "$d" || return 1
@@CORE_FILES@@
    return 0
}
