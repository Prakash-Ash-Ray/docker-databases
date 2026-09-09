#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

BASE_DIR="$HOME/dev/databases"

DATABASES=()
LABELS=()
SELECTED=()
STATUSES=()
CONTAINER_STATUSES=()

CURSOR=0

DOCKER_AVAILABLE=false


# ─────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────

RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
GRAY=$'\033[90m'
CYAN=$'\033[36m'

# Terminal control
CLEAR_SCREEN=$'\033[2J'
CURSOR_HOME=$'\033[H'
CURSOR_HIDE=$'\033[?25l'
CURSOR_SHOW=$'\033[?25h'


# ─────────────────────────────────────────────
# Discover databases
# ─────────────────────────────────────────────

load_databases() {
    DATABASES=()
    LABELS=()
    SELECTED=()
    STATUSES=()
    CONTAINER_STATUSES=()

    if [[ ! -d "$BASE_DIR" ]]; then
        echo "Error: database directory does not exist:"
        echo "$BASE_DIR"
        exit 1
    fi

    local directory
    local database
    local label

    # Only include visible directories directly under BASE_DIR.
    while IFS= read -r -d '' directory; do
        database="$(basename "$directory")"

        DATABASES+=("$database")

        # postgres     -> Postgres
        # my-database  -> My-database
        label="${database^}"
        LABELS+=("$label")

        SELECTED+=(false)
        STATUSES+=("UNKNOWN")
        CONTAINER_STATUSES+=("")
    done < <(
        find "$BASE_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            ! -name '.*' \
            -print0 |
            sort -z
    )

    # Make sure cursor is still valid.
    local menu_size
    menu_size=$(get_menu_size)

    if (( menu_size > 0 && CURSOR >= menu_size )); then
        CURSOR=$((menu_size - 1))
    fi
}


# ─────────────────────────────────────────────
# Docker helpers
# ─────────────────────────────────────────────

compose_file_exists() {
    local directory="$1"

    [[ -f "$directory/compose.yaml" ||
       -f "$directory/compose.yml" ||
       -f "$directory/docker-compose.yaml" ||
       -f "$directory/docker-compose.yml" ]]
}


check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        DOCKER_AVAILABLE=false
        return 1
    fi

    # Make sure the Docker Compose plugin exists.
    if ! docker compose version >/dev/null 2>&1; then
        DOCKER_AVAILABLE=false
        return 1
    fi

    # Make sure the Docker daemon is actually running.
    if ! docker info >/dev/null 2>&1; then
        DOCKER_AVAILABLE=false
        return 1
    fi

    DOCKER_AVAILABLE=true
    return 0
}


# ─────────────────────────────────────────────
# Docker status
# ─────────────────────────────────────────────

refresh_database_status() {
    local index="$1"
    local database="${DATABASES[$index]}"
    local directory="$BASE_DIR/$database"

    STATUSES[$index]="N/A"
    CONTAINER_STATUSES[$index]=""

    # No compose file.
    if ! compose_file_exists "$directory"; then
        return 0
    fi

    # Docker unavailable.
    if [[ "$DOCKER_AVAILABLE" != true ]]; then
        return 0
    fi

    local output

    # One docker compose call provides both:
    # - overall database status
    # - individual container status
    if ! output=$(
        cd "$directory" &&
        docker compose ps \
            -a \
            --format '{{.Name}}|{{.Service}}|{{.State}}' \
            2>/dev/null
    ); then
        STATUSES[$index]="ERROR"
        return 0
    fi

    CONTAINER_STATUSES[$index]="$output"

    local total=0
    local running=0

    local name
    local service
    local state

    while IFS='|' read -r name service state; do
        [[ -n "$name" ]] || continue

        # Do not use ((total++)) with `set -e`.
        # The first evaluation of ((total++)) returns exit code 1
        # because the old value is 0.
        total=$((total + 1))

        if [[ "$state" == "running" ]]; then
            running=$((running + 1))
        fi
    done <<< "$output"

    if (( total == 0 )); then
        STATUSES[$index]="EMPTY"
    elif (( running == total )); then
        STATUSES[$index]="RUNNING"
    elif (( running == 0 )); then
        STATUSES[$index]="STOPPED"
    else
        STATUSES[$index]="PARTIAL"
    fi
}


refresh_statuses() {
    local i

    for i in "${!DATABASES[@]}"; do
        refresh_database_status "$i"
    done
}


# ─────────────────────────────────────────────
# Status display
# ─────────────────────────────────────────────

get_status_icon() {
    local status="$1"

    case "$status" in
        RUNNING)
            printf '%s●%s' "$GREEN" "$RESET"
            ;;

        PARTIAL)
            printf '%s◐%s' "$YELLOW" "$RESET"
            ;;

        STOPPED)
            printf '%s○%s' "$RED" "$RESET"
            ;;

        EMPTY)
            printf '%s◇%s' "$GRAY" "$RESET"
            ;;

        ERROR)
            printf '%s!%s' "$RED" "$RESET"
            ;;

        *)
            printf '%s?%s' "$GRAY" "$RESET"
            ;;
    esac
}


get_status_color() {
    local status="$1"

    case "$status" in
        RUNNING)
            printf '%s' "$GREEN"
            ;;

        PARTIAL)
            printf '%s' "$YELLOW"
            ;;

        STOPPED)
            printf '%s' "$RED"
            ;;

        ERROR)
            printf '%s' "$RED"
            ;;

        *)
            printf '%s' "$GRAY"
            ;;
    esac
}


print_database_status() {
    local index="$1"
    local status="${STATUSES[$index]}"
    local color

    color="$(get_status_color "$status")"

    printf '%s %s%-8s%s' \
        "$(get_status_icon "$status")" \
        "$color" \
        "$status" \
        "$RESET"
}


print_container_statuses() {
    local index="$1"
    local output="${CONTAINER_STATUSES[$index]}"

    [[ -n "$output" ]] || return 0

    local name
    local service
    local state

    local first=true

    while IFS='|' read -r name service state; do
        [[ -n "$name" ]] || continue

        local icon
        local color

        if [[ "$state" == "running" ]]; then
            icon="●"
            color="$GREEN"
        else
            icon="○"
            color="$RED"
        fi

        if [[ "$first" == true ]]; then
            printf '      └─ '
            first=false
        else
            printf '      ├─ '
        fi

        printf '%-20s %s%s%s\n' \
            "$service" \
            "$color" \
            "$icon $state" \
            "$RESET"

    done <<< "$output"
}


# ─────────────────────────────────────────────
# Database operations
# ─────────────────────────────────────────────

start_database() {
    local database="$1"
    local directory="$BASE_DIR/$database"

    echo "▶ Starting $database..."

    (
        cd "$directory"
        docker compose up -d
    )
}


stop_database() {
    local database="$1"
    local directory="$BASE_DIR/$database"

    echo "■ Stopping $database..."

    (
        cd "$directory"
        docker compose down
    )
}


restart_database() {
    local database="$1"
    local directory="$BASE_DIR/$database"

    echo "↻ Restarting $database..."

    (
        cd "$directory"
        docker compose restart
    )
}


# ─────────────────────────────────────────────
# Selection
# ─────────────────────────────────────────────

is_any_selected() {
    local selected

    for selected in "${SELECTED[@]}"; do
        if [[ "$selected" == true ]]; then
            return 0
        fi
    done

    return 1
}


toggle_selected() {
    local index="$1"

    if [[ "${SELECTED[$index]}" == true ]]; then
        SELECTED[$index]=false
    else
        SELECTED[$index]=true
    fi
}


select_all() {
    local i

    for i in "${!DATABASES[@]}"; do
        SELECTED[$i]=true
    done
}


select_none() {
    local i

    for i in "${!DATABASES[@]}"; do
        SELECTED[$i]=false
    done
}


# ─────────────────────────────────────────────
# Menu
# ─────────────────────────────────────────────

get_menu_size() {
    # Databases + 4 actions.
    echo $(( ${#DATABASES[@]} + 4 ))
}


draw_action() {
    local index="$1"
    local label="$2"

    if (( CURSOR == index )); then
        printf '\033[7m  %-35s\033[0m\n' "$label"
    else
        printf '  %s\n' "$label"
    fi
}


draw_menu() {
    # Do NOT refresh Docker status here.
    #
    # draw_menu() is called after every keypress.
    # Calling Docker here makes keyboard navigation lag.

    printf '%s%s' "$CURSOR_HOME" "$CLEAR_SCREEN"

    printf '╭───────────────────────────────────────────────────────────╮\n'
    printf '│                Database Container Manager                 │\n'
    printf '╰───────────────────────────────────────────────────────────╯\n'
    printf '\n'

    local i
    local checkbox

    if (( ${#DATABASES[@]} == 0 )); then
        printf '  No databases found.\n'
    else
        for i in "${!DATABASES[@]}"; do
            checkbox="[ ]"

            if [[ "${SELECTED[$i]}" == true ]]; then
                checkbox="[X]"
            fi

            if (( CURSOR == i )); then
                printf '\033[7m  %s %-22s ' \
                    "$checkbox" \
                    "${LABELS[$i]}"

                print_database_status "$i"

                printf '\033[0m\n'
            else
                printf '  %s %-22s ' \
                    "$checkbox" \
                    "${LABELS[$i]}"

                print_database_status "$i"

                printf '\n'
            fi

            print_container_statuses "$i"

            if (( i < ${#DATABASES[@]} - 1 )); then
                printf '\n'
            fi
        done
    fi

    printf '\n'
    printf '  ──────────────────────────────────────────────────\n'

    local action_start=${#DATABASES[@]}

    draw_action "$action_start" \
        "▶  Start Selected"

    draw_action "$((action_start + 1))" \
        "■  Stop Selected"

    draw_action "$((action_start + 2))" \
        "↻  Restart Selected"

    printf '\n'

    draw_action "$((action_start + 3))" \
        "✕  Quit"

    printf '\n'
    printf '  ↑/↓ Navigate   Space Toggle   Enter Run\n'
    printf '  a Select all   n Select none   r Refresh   q Quit\n'
}


# ─────────────────────────────────────────────
# Cursor
# ─────────────────────────────────────────────

move_cursor_up() {
    local menu_size

    menu_size=$(get_menu_size)

    (( menu_size > 0 )) || return 0

    CURSOR=$((CURSOR - 1))

    if (( CURSOR < 0 )); then
        CURSOR=$((menu_size - 1))
    fi
}


move_cursor_down() {
    local menu_size

    menu_size=$(get_menu_size)

    (( menu_size > 0 )) || return 0

    CURSOR=$((CURSOR + 1))

    if (( CURSOR >= menu_size )); then
        CURSOR=0
    fi
}


# ─────────────────────────────────────────────
# Operations
# ─────────────────────────────────────────────

run_selected() {
    local operation="$1"
    local title="$2"

    printf '%s%s' "$CURSOR_HOME" "$CLEAR_SCREEN"

    if ! is_any_selected; then
        printf 'Nothing selected.\n'
        printf '\n'
        read -rp "Press Enter to continue..."
        return 0
    fi

    printf '%s\n\n' "$title"

    local i
    local failed=0

    for i in "${!DATABASES[@]}"; do
        if [[ "${SELECTED[$i]}" != true ]]; then
            continue
        fi

        local database="${DATABASES[$i]}"
        local status="${STATUSES[$i]}"

        case "$operation" in
            start)
                if [[ "$status" == "RUNNING" ]]; then
                    printf '✓ %s is already running — skipped.\n' "$database"
                else
                    if ! start_database "$database"; then
                        failed=1
                    fi
                fi
                ;;

            stop)
                if [[ "$status" == "STOPPED" ||
                      "$status" == "EMPTY" ]]; then
                    printf '✓ %s is already stopped — skipped.\n' "$database"
                else
                    if ! stop_database "$database"; then
                        failed=1
                    fi
                fi
                ;;

            restart)
                if [[ "$status" == "STOPPED" ||
                      "$status" == "EMPTY" ]]; then
                    printf '✓ %s is not running — skipped.\n' "$database"
                else
                    if ! restart_database "$database"; then
                        failed=1
                    fi
                fi
                ;;

            *)
                printf 'Unknown operation: %s\n' "$operation"
                return 1
                ;;
        esac

        printf '\n'
    done

    if (( failed == 0 )); then
        printf 'Done.\n'
    else
        printf 'Completed with errors.\n'
    fi

    printf '\n'
    read -rp "Press Enter to continue..."

    # Refresh once after operations.
    refresh_statuses
}


start_selected() {
    run_selected "start" "Starting selected databases..."
}


stop_selected() {
    run_selected "stop" "Stopping selected databases..."
}


restart_selected() {
    run_selected "restart" "Restarting selected databases..."
}


# ─────────────────────────────────────────────
# Actions
# ─────────────────────────────────────────────

execute_action() {
    local database_count="${#DATABASES[@]}"
    local action_start="$database_count"

    # Cursor is on a database.
    if (( CURSOR < database_count )); then
        toggle_selected "$CURSOR"
        return
    fi

    # Cursor is on an action.
    case "$CURSOR" in
        "$action_start")
            start_selected
            ;;

        "$((action_start + 1))")
            stop_selected
            ;;

        "$((action_start + 2))")
            restart_selected
            ;;

        "$((action_start + 3))")
            exit 0
            ;;

        *)
            printf 'Invalid menu selection.\n'
            sleep 1
            ;;
    esac
}


# ─────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────

cleanup() {
    printf '%s' "$CURSOR_SHOW"
    printf '%s%s' "$CURSOR_HOME" "$CLEAR_SCREEN"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


# ─────────────────────────────────────────────
# Initialization
# ─────────────────────────────────────────────

if ! check_docker; then
    printf 'Error: Docker or Docker Compose is not available.\n'
    printf '\n'
    printf 'Make sure:\n'
    printf '  1. Docker is installed.\n'
    printf '  2. Docker Compose is installed.\n'
    printf '  3. The Docker daemon is running.\n'
    printf '\n'
    exit 1
fi

load_databases

# Initial Docker status refresh.
# This happens only once before the UI starts.
refresh_statuses

# Hide cursor.
printf '%s' "$CURSOR_HIDE"


# ─────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────

while true; do
    draw_menu

    IFS= read -rsn1 key || break

    case "$key" in

        # ─────────────────────────────────────
        # Arrow keys
        # ─────────────────────────────────────

        $'\x1b')
            # Avoid blocking forever if Escape is pressed by itself.
            IFS= read -rsn2 -t 0.1 key || true

            case "$key" in
                '[A')
                    move_cursor_up
                    ;;

                '[B')
                    move_cursor_down
                    ;;
            esac
            ;;


        # ─────────────────────────────────────
        # Space
        # ─────────────────────────────────────

        ' ')
            if (( CURSOR < ${#DATABASES[@]} )); then
                toggle_selected "$CURSOR"
            fi
            ;;


        # ─────────────────────────────────────
        # Select all
        # ─────────────────────────────────────

        a|A)
            select_all
            ;;


        # ─────────────────────────────────────
        # Select none
        # ─────────────────────────────────────

        n|N)
            select_none
            ;;


        # ─────────────────────────────────────
        # Refresh
        # ─────────────────────────────────────

        r|R)
            # Re-discover databases and refresh Docker state.
            load_databases
            refresh_statuses
            ;;


        # ─────────────────────────────────────
        # Quit
        # ─────────────────────────────────────

        q|Q)
            exit 0
            ;;


        # ─────────────────────────────────────
        # Enter
        # ─────────────────────────────────────

        '')
            execute_action
            ;;

    esac
done

