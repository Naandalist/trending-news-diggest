set -euo pipefail

if [ -f .env ]; then
  set -o allexport
  source .env
  set +o allexport
fi

: "${URL_HOME:?URL_HOME must be set in .env}"
: "${URL_DETAIL:?URL_DETAIL must be set in .env}"
: "${AI_ENDPOINT:?AI_ENDPOINT must be set in .env}"
: "${USER_AGENT:?USER_AGENT must be set in .env}"
: "${HOST_HEADER:?HOST_HEADER must be set in .env}"

# Prereqs
for cmd in curl jq pandoc git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo >&2 "Error: '$cmd' is required; install it and retry."
    exit 1
  fi
done

TS=$(date +"%d%b%Y")
BASE_DIR="${ARCHIVE_BASE:-./archive}/$TS"
mkdir -p "$BASE_DIR"

HEADERS=(
  -H "Accept: */*"
  -H "Accept-Encoding: gzip, deflate, br"
  -H "Connection: keep-alive"
  -H "User-Agent: $USER_AGENT"
  -H "Host: $HOST_HEADER"
)

GUIDS=$(curl -sS --compressed "${HEADERS[@]}" "$URL_HOME" \
  | jq -r '.latest[].guid')

TOTAL=$(printf '%s\n' "$GUIDS" | wc -l | tr -d ' ')
i=0

while IFS= read -r GUID; do
  ((i++))
  CLEAN=${GUID#.}
  OUT="$BASE_DIR/$CLEAN.md"

  DETAIL_JSON=$(
    curl -sS --compressed "${HEADERS[@]}" \
      "${URL_DETAIL}?guid=$GUID" \
    | jq '.result'
  )

  TITLE=$(jq -r '.title'        <<<"$DETAIL_JSON")
  DESC=$(jq -r '.description'   <<<"$DETAIL_JSON")
  URLS=$(jq -r '.urlshort'      <<<"$DETAIL_JSON")
  AUTHOR=$(jq -r '.author.name' <<<"$DETAIL_JSON")
  EDITOR=$(jq -r '.editor.name' <<<"$DETAIL_JSON")

  MD_CONTENT=$(
    jq -r '.content[] 
           | select(test("Baca juga:") | not)' <<<"$DETAIL_JSON" \
    | {
        echo '<!DOCTYPE html><html><body>'
        cat
        echo '</body></html>'
      } \
    | pandoc -f html -t markdown --wrap=none
  )

  # Build AI prompt
  PROMPT="Act as a sharp, insightful, and humorous indonesia commentator. \
Provide a concise, one-paragraph summary of the news report in bahasa. \
Following that, in a separate paragraph, share your take on the positive \
and negative sides of the information, sprinkled with maximum painful satire. \
Context is: $MD_CONTENT"

  sleep 1

  AI_REQ=$(jq -nc --arg m "$PROMPT" '{model:"gpt-4o",messages:[{role:"user",content:$m}]}')
  AI_SUMMARY_RAW=$(
    curl -sS -X POST "$AI_ENDPOINT" \
      -H "Content-Type: application/json" \
      -d "$AI_REQ" \
    | jq -r '.choices[0].message.content'
  )

  AI_SUMMARY=$(printf '%s' "$AI_SUMMARY_RAW" | sed -E 's/\.\s*/.\n\n/g')

  {
    echo "# $TITLE"
    echo
    echo "$DESC"
    echo

    echo "| Field       | Value                                                       |"
    echo "|-------------|-------------------------------------------------------------|"
    printf "| title       | %s |\n"       "${TITLE//|/\\|}"
    printf "| description | %s |\n" "${DESC//|/\\|}"
    printf "| urlshort    | %s |\n"    "$URLS"
    printf "| author      | %s |\n"      "${AUTHOR//|/\\|}"
    printf "| editor      | %s |\n"      "${EDITOR//|/\\|}"
    echo

    printf '%s\n\n' "$MD_CONTENT"
    echo '---'
    printf '%s\n' "$AI_SUMMARY"
  } > "$OUT"

  git add "$OUT"
  git commit -m "feat: add $TITLE"
  echo "✅ [$i/$TOTAL] Written & committed → $OUT"
done <<< "$GUIDS"

echo "🚀 Pushing to origin main…"
git push -u origin main
echo "✅ Done! All articles processed and pushed to origin main."