#!/bin/bash

set -e

cd "$(dirname "$0")/.." || exit

if [[ -z "$PROMPT_CACHE_FILE" || -z "$CHAT_SAVE_DIR" ]]; then
    echo >&2 "error: PROMPT_CACHE_FILE and CHAT_SAVE_DIR must be provided"
    exit 1
fi

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

PROMPT_EVAL_MSG_PATTERN='prompt eval time =\s+\d+.\d+ ms /\s+\d+ tokens' 

CTX_SIZE=2048
CTX_ROTATE_POINT=$((CTX_SIZE * 3 / 5)) # REVIEW
OPTS=(--model ./models/13B/ggml-model-q4_0.bin --ctx_size "$CTX_SIZE" --repeat_last_n 256 "$@")

mkdir -p "$CHAT_SAVE_DIR"
echo >"$LOG"
trap "tail -n50 ${LOG}" EXIT

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

# TODO: strip newline at end
cat "$CUR_PROMPT_FILE"
n_tokens=0

while read line; do
    printf '%s: ' "$AI_NAME"
    printf '%s\n%s: ' "$line" "$AI_NAME" >>"$CUR_PROMPT_FILE"

    output=""
    while ((n_tokens + 10 < CTX_SIZE)); do
        prompt_len=$(($(wc -c <"$CUR_PROMPT_FILE") - 1))
        prompt_and_chunk="$(
            ./main 2>>"$LOG" "${OPTS[@]}" \
                --prompt-cache "$CUR_PROMPT_CACHE" \
                --prompt-cache-all \
                --file "$CUR_PROMPT_FILE" \
                --n_predict 5
        )"
        chunk="${prompt_and_chunk:${prompt_len}}"
        raw_output="${output}${chunk}"
        output="$(sed "/^${USER_NAME}:/,\$d" <<<"$raw_output")"

        is_done=0
        if [[ "$raw_output" != "$output" ]]; then
            output="${output}"$'\n'"${USER_NAME}:"
            chunk="${chunk%:*}: "
            is_done=1
        fi

        printf '%s' "$chunk"
        printf '%s' "$chunk" >>"$CUR_PROMPT_FILE"

        # HACK get # tokens from debug message
        if ! prompt_eval_msg="$(tail -n10 "$LOG" | grep -oE "$PROMPT_EVAL_MSG_PATTERN")"; then
            echo >&2 "Couldn't get number of prompt tokens!"
            exit 1
        fi

        n_tokens=$((5 + $(awk '{print $8}' <<<"$prompt_eval_msg")))

        if [[ "$is_done" == 1 ]]; then
            break
        fi
    done

    if ((n_tokens > CTX_ROTATE_POINT)); then
        tail -c+$((orig_prompt_len)) "$CUR_PROMPT_FILE" >>"$NEXT_PROMPT_FILE"
    fi

    if ((n_tokens + 10 > CTX_SIZE)); then
        echo
        echo "--- CONTEXT SWAP ---"
        cat "$NEXT_PROMPT_FILE"
        echo "<<<END"

        wait
        mv "$NEXT_PROMPT_FILE"  "$CUR_PROMPT_FILE"
        mv "$NEXT_PROMPT_CACHE" "$CUR_PROMPT_CACHE"
    fi

    ./main >>"$LOG_BG" 2>&1 "${OPTS[@]}" \
          --prompt-cache "$NEXT_PROMPT_CACHE" \
          --file "$NEXT_PROMPT_FILE" \
          --n_predict 1 &
done
