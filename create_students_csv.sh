#!/bin/bash
################################################################################
# Script : create_students_csv.sh
# Description : Création d'étudiants Proxmox depuis un CSV, à la suite des
#               numéros existants (tech_N@pve, pool_N, bridge isolé vmbrN)
# Usage : ./create_students_csv.sh <fichier.csv> "<promotion>"
# Exemple : ./create_students_csv.sh sal4.csv "SIO 26-28 SAL4"
# CSV : nom;prenom;email  (en-tête obligatoire, email facultatif, séparateur ;)
#
# Pour chaque élève, le script crée :
#   - le compte tech_N@pve (prénom, nom, e-mail, promotion en commentaire),
#     membre du groupe etudiants (stockages local / local-lvm, vmbr0) ;
#   - le pool pool_N, avec PVEVMAdmin + PoolEtudiant ;
#   - le bridge isolé vmbrN (bridge-ports none), avec PVESDNUser.
# N part du plus grand numéro déjà utilisé (comptes, pools, bridges) + 1.
# Un élève dont le prénom + nom existe déjà sur un compte tech_* est ignoré :
# relancer le script sur le même CSV ne crée pas de doublon.
#
# Les bridges sont créés par l'API puis appliqués en une fois (ifreload),
# après sauvegarde de /etc/network/interfaces. Le script refuse de démarrer
# si des modifications réseau sont déjà en attente (interfaces.new).
#
# Réglages modifiables sans toucher au script :
#   GROUP=etudiants USER_PREFIX=tech_ POOL_PREFIX=pool_ BRIDGE_PREFIX=vmbr REALM=pve
################################################################################

if [ $# -ne 2 ]; then
    echo "Usage: $0 <fichier.csv> \"<promotion>\""
    echo "Exemple: $0 sal4.csv \"SIO 26-28 SAL4\""
    exit 1
fi

CSV="$1"
PROMO="$2"
GROUP="${GROUP:-etudiants}"
USER_PREFIX="${USER_PREFIX:-tech_}"
POOL_PREFIX="${POOL_PREFIX:-pool_}"
BRIDGE_PREFIX="${BRIDGE_PREFIX:-vmbr}"
REALM="${REALM:-pve}"
NODE="$(hostname)"

[ "$(id -u)" -eq 0 ] || { echo "❌ À lancer en root sur le nœud Proxmox"; exit 1; }
[ -f "$CSV" ] || { echo "❌ Fichier introuvable : $CSV"; exit 1; }
command -v jq &>/dev/null || { apt update && apt install -y jq; }

if [ -e /etc/network/interfaces.new ]; then
    echo "❌ Des modifications réseau sont en attente (/etc/network/interfaces.new)."
    echo "   Les appliquer ou les annuler dans l'interface (nœud ▸ Réseau) avant de relancer."
    exit 1
fi

if ! pvesh get /access/groups --output-format=json | jq -e --arg g "$GROUP" '.[] | select(.groupid==$g)' >/dev/null; then
    echo "❌ Groupe introuvable : $GROUP"
    exit 1
fi

# État actuel, lu une fois
USERS_JSON=$(pvesh get /access/users --output-format=json)
POOLS=$(pvesh get /pools --output-format=json | jq -r '.[].poolid')
BRIDGES=$(pvesh get "/nodes/$NODE/network" --type bridge --output-format=json | jq -r '.[].iface')

# Plus grand numéro utilisé par un compte, un pool ou un bridge
MAX=$( {
    jq -r '.[].userid' <<<"$USERS_JSON" | sed -nE "s/^${USER_PREFIX}([0-9]+)@${REALM}\$/\1/p"
    sed -nE "s/^${POOL_PREFIX}([0-9]+)\$/\1/p" <<<"$POOLS"
    sed -nE "s/^${BRIDGE_PREFIX}([0-9]+)\$/\1/p" <<<"$BRIDGES"
    echo 0
} | sort -n | tail -1 )

# Prénom + nom déjà présents sur un compte tech_* (comparaison sans casse)
KNOWN=$(jq -r --arg p "$USER_PREFIX" '.[] | select(.userid | startswith($p)) |
    "\(.firstname // "")|\(.lastname // "")" | ascii_downcase' <<<"$USERS_JSON")

# Lecture du CSV : BOM Excel, fins de ligne Windows, en-tête, dernière ligne
# sans retour final ; numérotation des nouveaux
NUMS=(); NOMS=(); PRENOMS=(); EMAILS=(); IGNORES=()
N=$MAX
while IFS=';' read -r NOM PRENOM EMAIL || [[ -n "$NOM" ]]; do
    NOM=$(echo "$NOM" | sed -E 's/^\s+|\s+$//g')
    PRENOM=$(echo "$PRENOM" | sed -E 's/^\s+|\s+$//g')
    EMAIL=$(echo "$EMAIL" | tr -d '[:space:]')
    [[ -z "$NOM" || "$NOM" == \#* ]] && continue
    if [[ -z "$PRENOM" ]]; then
        IGNORES+=("$NOM (prénom manquant)"); continue
    fi
    KEY=$(echo "$PRENOM|$NOM" | tr '[:upper:]' '[:lower:]')
    if grep -qxF "$KEY" <<<"$KNOWN"; then
        IGNORES+=("$PRENOM $NOM (compte déjà existant)"); continue
    fi
    KNOWN+=$'\n'"$KEY"
    N=$((N+1))
    NUMS+=("$N"); NOMS+=("$NOM"); PRENOMS+=("$PRENOM"); EMAILS+=("$EMAIL")
done < <(sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$CSV" | tail -n +2)

echo "=========================================="
echo "Nœud       : $NODE"
echo "Promotion  : $PROMO"
echo "Groupe     : $GROUP"
echo "Dernier n° : $MAX"
echo "=========================================="
for i in "${!NUMS[@]}"; do
    printf '  %s%-3s %s%-3s %s%-3s  %s %s\n' "$USER_PREFIX" "${NUMS[$i]}" "$POOL_PREFIX" "${NUMS[$i]}" \
        "$BRIDGE_PREFIX" "${NUMS[$i]}" "${PRENOMS[$i]}" "${NOMS[$i]}"
done
for I in "${IGNORES[@]}"; do echo "  ⚠ ignoré : $I"; done
echo ""

if [ ${#NUMS[@]} -eq 0 ]; then
    echo "Aucun élève à créer."
    exit 0
fi

read -sp "Mot de passe commun : " PASSWORD; echo
read -sp "Confirmer : " PASSWORD_CONFIRM; echo
if [[ -z "$PASSWORD" || "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
    echo "❌ Mots de passe vides ou différents"
    exit 1
fi
if [ ${#PASSWORD} -lt 8 ]; then
    echo "❌ Mot de passe trop court (8 caractères minimum)"
    exit 1
fi

read -p "Créer ces ${#NUMS[@]} élèves ? (o/N) " -n 1 -r; echo
[[ $REPLY =~ ^[Oo]$ ]] || { echo "Annulé"; exit 0; }

STAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/root/proxmox_creation_${STAMP}.log"
OUT_CSV="/root/proxmox_identifiants_${STAMP}.csv"
echo "Utilisateur;Pool;Bridge;Nom;Prenom;Email;Promotion" > "$OUT_CSV"
chmod 600 "$OUT_CSV"
cp /etc/network/interfaces "/root/interfaces.avant_${STAMP}"
echo "Sauvegarde réseau : /root/interfaces.avant_${STAMP}" | tee -a "$LOG_FILE"

ERRORS=0
OK_IDX=()

# Étape 1 : compte, pool, droits sur le pool, bridge (en attente)
for i in "${!NUMS[@]}"; do
    NUM="${NUMS[$i]}"
    NEW_USER="${USER_PREFIX}${NUM}@${REALM}"
    NEW_POOL="${POOL_PREFIX}${NUM}"
    BRIDGE="${BRIDGE_PREFIX}${NUM}"
    echo "" | tee -a "$LOG_FILE"
    echo "━━━ $NEW_USER (${PRENOMS[$i]} ${NOMS[$i]}) ━━━" | tee -a "$LOG_FILE"

    echo -n "  [1/4] Compte... " | tee -a "$LOG_FILE"
    ARGS=(--password "$PASSWORD" --firstname "${PRENOMS[$i]}" --lastname "${NOMS[$i]}"
          --comment "$PROMO" --groups "$GROUP")
    [[ -n "${EMAILS[$i]}" ]] && ARGS+=(--email "${EMAILS[$i]}")
    if pveum user add "$NEW_USER" "${ARGS[@]}" >>"$LOG_FILE" 2>&1; then
        echo "✓" | tee -a "$LOG_FILE"
    else
        echo "❌ (voir log), élève suivant" | tee -a "$LOG_FILE"
        ERRORS=$((ERRORS+1)); continue
    fi

    FAILED=0
    echo -n "  [2/4] Pool... " | tee -a "$LOG_FILE"
    if pvesh create /pools --poolid "$NEW_POOL" --comment "Pool etudiant ${USER_PREFIX}${NUM} - bridge $BRIDGE" >>"$LOG_FILE" 2>&1 \
       && pveum acl modify "/pool/$NEW_POOL" --users "$NEW_USER" --roles PVEVMAdmin,PoolEtudiant --propagate 1 >>"$LOG_FILE" 2>&1; then
        echo "✓" | tee -a "$LOG_FILE"
    else
        echo "❌" | tee -a "$LOG_FILE"; FAILED=1
    fi

    echo -n "  [3/4] Bridge $BRIDGE... " | tee -a "$LOG_FILE"
    if pvesh create "/nodes/$NODE/network" --iface "$BRIDGE" --type bridge --autostart 1 \
         --comments "${USER_PREFIX}${NUM}" >>"$LOG_FILE" 2>&1; then
        echo "✓ (en attente)" | tee -a "$LOG_FILE"
        OK_IDX+=("$i")
    else
        echo "❌" | tee -a "$LOG_FILE"; FAILED=1
    fi

    echo "${NEW_USER};${NEW_POOL};${BRIDGE};${NOMS[$i]};${PRENOMS[$i]};${EMAILS[$i]};${PROMO}" >> "$OUT_CSV"
    [ $FAILED -eq 1 ] && ERRORS=$((ERRORS+1))
done

# Étape 2 : application des bridges en une fois
echo "" | tee -a "$LOG_FILE"
if [ ${#OK_IDX[@]} -gt 0 ]; then
    echo -n "Application de la configuration réseau... " | tee -a "$LOG_FILE"
    if pvesh set "/nodes/$NODE/network" >>"$LOG_FILE" 2>&1; then
        echo "✓" | tee -a "$LOG_FILE"
    else
        echo "❌ (voir log ; sauvegarde : /root/interfaces.avant_${STAMP})" | tee -a "$LOG_FILE"
        ERRORS=$((ERRORS+1)); OK_IDX=()
    fi
fi

# Étape 3 : droit sur son bridge, une fois celui-ci actif
for i in "${OK_IDX[@]}"; do
    NUM="${NUMS[$i]}"
    echo -n "  [4/4] ${USER_PREFIX}${NUM} : droit sur ${BRIDGE_PREFIX}${NUM}... " | tee -a "$LOG_FILE"
    if pveum acl modify "/sdn/zones/localnetwork/${BRIDGE_PREFIX}${NUM}" --users "${USER_PREFIX}${NUM}@${REALM}" \
         --roles PVESDNUser --propagate 1 >>"$LOG_FILE" 2>&1; then
        echo "✓" | tee -a "$LOG_FILE"
    else
        echo "❌" | tee -a "$LOG_FILE"; ERRORS=$((ERRORS+1))
    fi
done

echo ""
echo "=========================================="
echo "Élèves traités : ${#NUMS[@]} · En erreur : $ERRORS"
echo "Log          : $LOG_FILE"
echo "Identifiants : $OUT_CSV (chmod 600)"
echo "=========================================="
[ $ERRORS -eq 0 ]
