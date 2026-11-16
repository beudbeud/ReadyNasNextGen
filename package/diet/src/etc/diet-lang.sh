# Langue des messages DIET (journaux, diet-status, Telegram) : /etc/diet-lang = fr | de | en (anglais par défaut).
# Utilisation : . /etc/diet-lang.sh ; tx "français" "deutsch" "english"
L=$(cat ${DIET_RACINE:-}/etc/diet-lang 2>/dev/null)
case "$L" in fr|de|en) ;; *) L=en ;; esac
tx() { case $L in fr) printf '%s' "$1" ;; de) printf '%s' "$2" ;; *) printf '%s' "$3" ;; esac; }
