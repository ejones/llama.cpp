#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.." || exit

if [[ -z "${PROMPT_CACHE_FILE+x}" || -z "${CHAT_SAVE_DIR+x}" ]]; then
    echo >&2 "error: PROMPT_CACHE_FILE and CHAT_SAVE_DIR must be provided"
    exit 1
fi

MODEL="${MODEL:-./models/13B/ggml-model-q4_0.bin}"
PROMPT_TEMPLATE="${PROMPT_TEMPLATE:-./prompts/chat.txt}"
USER_NAME="${USER_NAME:-User}"
AI_NAME="${AI_NAME:-ChatLLaMa}"
DATE_TIME="$(date +%H:%M)"
DATE_YEAR="$(date +%Y)"

LOG="${CHAT_SAVE_DIR}/main.log"
LOG_BG="${CHAT_SAVE_DIR}/main-bg.log"
CUR_PROMPT_FILE="${CHAT_SAVE_DIR}/current-prompt.txt"
CUR_PROMPT_CACHE="${CHAT_SAVE_DIR}/current-cache.bin"
NEXT_PROMPT_FILE="${CHAT_SAVE_DIR}/next-prompt.txt"
NEXT_PROMPT_CACHE="${CHAT_SAVE_DIR}/next-cache.bin"

SESSION_SIZE_MSG_PATTERN='main: session file matches \d+ / \d+'
SAMPLE_TIME_MSG_PATTERN='sample time =\s+\d+.\d+ ms /\s+\d+' 

CTX_SIZE=2048
CTX_ROTATE_POINT=$((CTX_SIZE * 3 / 5)) # REVIEW
OPTS=(--model "$MODEL" --ctx_size "$CTX_SIZE" --repeat_last_n 256 "$@")

skip_bytes() {
    LANG=C IFS= read -r -n "$1" -d '' c
    while LANG=C IFS= read -r -n 1 -d '' c; do
        printf '%s' "$c"
    done
}

mkdir -p "$CHAT_SAVE_DIR"
echo >"$LOG"
trap "tail -n100 ${LOG}" EXIT

if [[ ! -e "$CUR_PROMPT_FILE" ]]; then
    sed -e "s/\[\[USER_NAME\]\]/${USER_NAME}/g" \
        -e "s/\[\[AI_NAME\]\]/${AI_NAME}/g" \
        -e "s/\[\[DATE_TIME\]\]/${DATE_TIME}/g" \
        -e "s/\[\[DATE_YEAR\]\]/${DATE_YEAR}/g" \
        "$PROMPT_TEMPLATE" >"$CUR_PROMPT_FILE"
fi

sed -r '/^('"$USER_NAME"':|'"$AI_NAME"':|\.\.\.)/,$d' "$CUR_PROMPT_FILE" >"$NEXT_PROMPT_FILE"
echo '...' >>"$NEXT_PROMPT_FILE"

if [[ ! -e "$PROMPT_CACHE_FILE" ]]; then
    echo 'Prompt cache does not exist, building...'
    ./main 2>>"$LOG" \
        --batch_size 8 \
        "${OPTS[@]}" \
        --prompt-cache "$PROMPT_CACHE_FILE" \
        --file "$CUR_PROMPT_FILE" \
        --n_predict 1
    echo $'\nDone!'
fi

if [[ ! -e "$CUR_PROMPT_CACHE" ]]; then
    cp "$PROMPT_CACHE_FILE" "$CUR_PROMPT_CACHE"
fi
cp "$PROMPT_CACHE_FILE" "$NEXT_PROMPT_CACHE"

printf '%s ' "$(< "$CUR_PROMPT_FILE")"
n_tokens=0

while read -e line; do
    echo " ${line}" >>"$CUR_PROMPT_FILE"
    if ((n_tokens > CTX_ROTATE_POINT)); then
        echo " ${line}" >>"$NEXT_PROMPT_FILE"
    fi

    n_prompt_len_pre=$(($(wc -c <"$CUR_PROMPT_FILE")))
    n_predict=$((CTX_SIZE - n_tokens - 4))

    printf '%s: ' "$AI_NAME" >>"$CUR_PROMPT_FILE"

    ./main 2>>"$LOG" "${OPTS[@]}" \
            --prompt-cache "$CUR_PROMPT_CACHE" \
            --prompt-cache-all \
            --file "$CUR_PROMPT_FILE" \
            --reverse-prompt "${USER_NAME}:" \
            --n_predict "$n_predict" |
        skip_bytes 1 | # main prepends + outputs BOS token at start
        tee "$CUR_PROMPT_FILE.tmp" |
        skip_bytes "$n_prompt_len_pre"

    printf ' '

    mv "$CUR_PROMPT_FILE.tmp" "$CUR_PROMPT_FILE"

    # TODO get both messages in one go
    # HACK get # tokens from debug message
    if  ! session_size_msg="$(tail -n30 "$LOG" | grep -oE "$SESSION_SIZE_MSG_PATTERN")" ||
        ! sample_time_msg="$( tail -n10 "$LOG" | grep -oE "$SAMPLE_TIME_MSG_PATTERN")"; then
        echo >&2 "Couldn't get number of tokens from ./main output!"
        exit 1
    fi

    n_tokens=$(($(cut -d/ -f2 <<<"$session_size_msg") + $(cut -d/ -f2 <<<"$sample_time_msg")))

    if ((n_tokens > CTX_ROTATE_POINT)); then
        tail -c+$((n_prompt_len_pre + 1)) "$CUR_PROMPT_FILE" >>"$NEXT_PROMPT_FILE"
    fi

    if ((n_tokens + 16 > CTX_SIZE)); then
        echo
        echo "--- CONTEXT SWAP ---"
        cat "$NEXT_PROMPT_FILE"
        echo "<<<END"

        wait
        mv "$NEXT_PROMPT_FILE"  "$CUR_PROMPT_FILE"
        mv "$NEXT_PROMPT_CACHE" "$CUR_PROMPT_CACHE"

        # TODO avoid duplication from above to init next prompt
        sed -r '/^('"$USER_NAME"':|'"$AI_NAME"':|\.\.\.)/,$d' "$CUR_PROMPT_FILE" >"$NEXT_PROMPT_FILE"
        echo '...' >>"$NEXT_PROMPT_FILE"
        cp "$PROMPT_CACHE_FILE" "$NEXT_PROMPT_CACHE"

        n_tokens=0
    fi

    ./main >>"$LOG_BG" 2>&1 "${OPTS[@]}" \
          --prompt-cache "$NEXT_PROMPT_CACHE" \
          --file "$NEXT_PROMPT_FILE" \
          --n_predict 1 &
done
