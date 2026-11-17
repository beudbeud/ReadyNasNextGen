# Language of DIET messages (logs, diet-status, Telegram): /etc/diet-lang = fr | de | en (English by default).
# Usage: . /etc/diet-lang.sh; tx "english" "français" "deutsch"
L=$(cat ${DIET_ROOT:-}/etc/diet-lang 2>/dev/null)
case "$L" in fr|de|en) ;; *) L=en ;; esac
tx() { case $L in fr) printf '%s' "$2" ;; de) printf '%s' "$3" ;; *) printf '%s' "$1" ;; esac; }
