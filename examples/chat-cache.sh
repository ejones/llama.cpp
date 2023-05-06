#!/bin/bash

set -e

cd "$(dirname "$0")/.." || exit

MODEL="${MODEL:-./models/13B/ggml-model-q4_0.bin}"
PROMPT_TEMPLATE=${PROMPT_TEMPLATE:-./prompts/chat.txt}
PROMPT_CACHE="${PROMPT_CACHE:-./chat-cache.bin}"
USER_NAME="${USER_NAME:-USER}"
AI_NAME="${AI_NAME:-ChatLLaMa}"

# Adjust to the number of CPU cores you want to use.
N_THREAD="${N_THREAD:-8}"
# Number of tokens to predict (made it larger than default because we want a long interaction)
N_PREDICTS="${N_PREDICTS:-2048}"

# Note: you can also override the generation options by specifying them on the command line:
# For example, override the context size by doing: ./chatLLaMa --ctx_size 1024
GEN_OPTIONS="${GEN_OPTIONS:---ctx_size 2048 --temp 0.7 --top_k 40 --top_p 0.5 --repeat_last_n 256 --batch_size 1024 --repeat_penalty 1.17647}"

DATE_TIME=$(date +%H:%M)
DATE_YEAR=$(date +%Y)

prompt="$(
sed -e "s/\[\[USER_NAME\]\]/$USER_NAME/g" \
    -e "s/\[\[AI_NAME\]\]/$AI_NAME/g" \
    -e "s/\[\[DATE_TIME\]\]/$DATE_TIME/g" \
    -e "s/\[\[DATE_YEAR\]\]/$DATE_YEAR/g" \
     $PROMPT_TEMPLATE
) "
prompt_first_line="$(head -n1 <<<"$prompt")"

echo >chat.log

if [[ ! -f "$PROMPT_CACHE" ]]; then
    echo 'Compiling prompt...'
    if ! ./main 2>>chat.log $GEN_OPTIONS \
          --prompt-cache "$PROMPT_CACHE" \
          --model "$MODEL" \
          --threads "$N_THREAD" \
          --prompt "$prompt" \
          --batch_size 8 \
          --n_predict 1 \
          "$@"; then
        tail -n 60 chat.log
        exit 1
    fi
else
    printf '%s' "$prompt"
fi

cp "$PROMPT_CACHE" "${PROMPT_CACHE}.leader"

while read line; do
    printf '%s: ' "$AI_NAME"
    prompt="${prompt}${line}
${AI_NAME}:"

    remaining=$(($(wc -c <<<"$prompt") + 1))
    output=""

    while IFS= read -d$'\0' -r -n1 char; do
        if [[ "$char" == $'\1' ]]; then
            tail -n 60 chat.log
            exit 1
        fi
        ((remaining--))
        if [[ "$remaining" -lt 1 ]]; then
            output="${output}${char}"
            printf '%c' "$char"
            if [[ "$output" == *$'\n'"${USER_NAME}:" ]]; then
                printf ' '
            fi
        fi
    done < <(
        # shellcheck disable=SC2086 # Intended splitting of GEN_OPTIONS
        ./main 2>>chat.log $GEN_OPTIONS \
          --prompt-cache "${PROMPT_CACHE}.leader" \
          --prompt-cache-all \
          --model "$MODEL" \
          --threads "$N_THREAD" \
          --n_predict "$N_PREDICTS" \
          --prompt "$prompt" \
          --reverse-prompt "${USER_NAME}:" \
          "$@" || echo $'\1'
    )

    prompt="${prompt}${output} "

    # TODO: token counts rather than chars
    if [[ $(($(wc -c <<<"$prompt"))) -gt 2730 ]]; then
        prompt="${trailing_prompt}${output} "
        echo
        echo "--- CONTEXT SWAP ---"
        echo "${prompt}<<<END" 

        wait
        mv "${PROMPT_CACHE}.trailer" "${PROMPT_CACHE}.leader"
    fi

    trailing_prompt="${prompt_first_line}

...${prompt:1536}"

    # shellcheck disable=SC2086 # Intended splitting of GEN_OPTIONS
    ./main >>chat.log 2>&1 $GEN_OPTIONS \
          --prompt-cache "${PROMPT_CACHE}.trailer" \
          --prompt-cache-all \
          --model "$MODEL" \
          --threads "$N_THREAD" \
          --n_predict 1 \
          --prompt "$trailing_prompt" \
          --reverse-prompt "${USER_NAME}:" \
          "$@" &
done
