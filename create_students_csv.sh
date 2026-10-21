#!/bin/bash
################################################################################
# Script : create_students_csv.sh
# Description : Création d'étudiants Proxmox (user + pool + ACL) depuis un CSV
# Usage : ./create_students_csv.sh <utilisateur_modele> <fichier.csv> [groupe]
# Exemple : ./create_students_csv.sh Pv2Etud27@pve etudiants.csv Etudiants
# CSV : num;nom;prenom;email  (en-tête obligatoire, email facultatif)
#
# Ce que reçoit chaque étudiant :
#   - les groupes du modèle, plus [groupe] s'il est donné (créé au besoin) ;
#   - les ACL directes du modèle, hors pools et hors VM - sauf les VM
#     modèles (templates), recopiées pour que l'étudiant puisse cloner ;
#   - son pool personnel <préfixe><num>, avec le rôle POOL_ROLE.
#
# Rôle sur le pool : PVEVMAdmin par défaut, modifiable sans toucher au script :
#   POOL_ROLE=PVEAdmin ./create_students_csv.sh ...
# PVEVMAdmin ne donne ni Datastore.AllocateSpace (disques) ni SDN.Use (cartes
# réseau, Proxmox 8) : ces droits doivent venir du modèle ou de son groupe.
# Toujours tester d'abord avec un CSV d'un seul étudiant.
################################################################################

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 <utilisateur_modele> <fichier.csv> [groupe]"
    echo "Exemple: $0 Pv2Etud27@pve etudiants.csv Etudiants"
    exit 1
fi

MODEL_USER="$1"
CSV="$2"
EXTRA_GROUP="${3:-}"
POOL_ROLE="${POOL_ROLE:-PVEVMAdmin}"

[ "$(id -u)" -eq 0 ] || { echo "❌ À lancer en root sur un nœud Proxmox"; exit 1; }
[ -f "$CSV" ] || { echo "❌ Fichier introuvable : $CSV"; exit 1; }

# Préfixe et realm déduits du modèle (Pv2Etud27@pve -> Pv2Etud / @pve)
REALM="@${MODEL_USER#*@}"
PREFIX=$(echo "${MODEL_USER%@*}" | sed -E 's/[0-9]+$//')

if [[ -z "$PREFIX" || "$REALM" == "@$MODEL_USER" ]]; then
    echo "❌ Format du modèle invalide (attendu : PvXEtudXX@pve)"
    exit 1
fi

# jq requis
command -v jq &>/dev/null || { apt update && apt install -y jq; }

# Le modèle doit exister
if ! pveum user list --output-format=json | jq -e --arg u "$MODEL_USER" '.[] | select(.userid==$u)' >/dev/null; then
    echo "❌ Utilisateur modèle introuvable : $MODEL_USER"
    exit 1
fi

# Groupes du modèle (+ groupe demandé), sans doublon
MODEL_GROUPS=$(pvesh get "/access/users/$MODEL_USER" --output-format=json | \
    jq -r '.groups // [] | if type=="string" then split(",") else . end | .[]')
GROUPS_LIST=$(printf '%s\n' $MODEL_GROUPS $EXTRA_GROUP | grep -v '^$' | sort -u | paste -sd, -)

if [[ -n "$EXTRA_GROUP" ]] && \
   ! pvesh get /access/groups --output-format=json | jq -e --arg g "$EXTRA_GROUP" '.[] | select(.groupid==$g)' >/dev/null; then
    CREATE_GROUP=1
fi

# VM modèles (templates) du cluster : leurs ACL sont gardées
TEMPLATE_PATHS=$(pvesh get /cluster/resources --type vm --output-format=json | \
    jq -r '.[] | select(.template==1) | "/vms/\(.vmid)"')

# ACL directes du modèle à recopier, lues une seule fois :
# on écarte /pool/* et les /vms/* qui ne sont pas des templates
mapfile -t MODEL_ACLS < <(
    pvesh get /access/acl --output-format=json | \
    jq -r --arg u "$MODEL_USER" '.[] | select(.ugid==$u and .type=="user") | "\(.path)|\(.roleid)|\(.propagate // 1)"' | \
    while IFS='|' read -r P R PROP; do
        if [[ "$P" == /pool/* ]]; then continue; fi
        if [[ "$P" == /vms/* ]] && ! grep -qxF "$P" <<<"$TEMPLATE_PATHS"; then continue; fi
        echo "$P|$R|$PROP"
    done
)

echo "=========================================="
echo "Création des étudiants depuis $CSV"
echo "=========================================="
echo "Modèle         : $MODEL_USER"
echo "Groupes        : ${GROUPS_LIST:-(aucun)}${CREATE_GROUP:+  ($EXTRA_GROUP sera créé)}"
echo "Rôle sur pool  : $POOL_ROLE"
echo "ACL recopiées  :"
if [ ${#MODEL_ACLS[@]} -eq 0 ]; then
    echo "   (aucune)"
else
    printf '   • %s\n' "${MODEL_ACLS[@]}"
fi
echo "Étudiants      : $(sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$CSV" | tail -n +2 | grep -cvE '^\s*(#|$)')"
echo ""

if [[ ${#MODEL_ACLS[@]} -eq 0 && -z "$GROUPS_LIST" ]]; then
    echo "⚠ Le modèle n'a ni ACL directe ni groupe : les étudiants n'auront"
    echo "  que leur pool (pas de stockage, pas de réseau, pas de template)."
    echo ""
fi

# Mot de passe commun
read -sp "Mot de passe commun : " PASSWORD; echo
read -sp "Confirmer : " PASSWORD_CONFIRM; echo
if [[ -z "$PASSWORD" || "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
    echo "❌ Mots de passe vides ou différents"
    exit 1
fi
if [ ${#PASSWORD} -lt 8 ]; then
    echo "❌ Mot de passe trop court (8 caractères minimum pour Proxmox)"
    exit 1
fi

read -p "Lancer la création ? (o/N) " -n 1 -r; echo
[[ $REPLY =~ ^[Oo]$ ]] || { echo "Annulé"; exit 0; }

STAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/root/proxmox_creation_${STAMP}.log"
OUT_CSV="/root/proxmox_identifiants_${STAMP}.csv"
echo "Utilisateur;Pool;Nom;Prenom;Email" > "$OUT_CSV"
chmod 600 "$OUT_CSV"

if [[ -n "$CREATE_GROUP" ]]; then
    if pveum group add "$EXTRA_GROUP" --comment "Étudiants" >>"$LOG_FILE" 2>&1; then
        echo "✓ Groupe $EXTRA_GROUP créé" | tee -a "$LOG_FILE"
    else
        echo "❌ Impossible de créer le groupe $EXTRA_GROUP (voir $LOG_FILE)"; exit 1
    fi
fi

# Pools existants, lus une fois puis tenus à jour
EXISTING_POOLS=$(pvesh get /pools --output-format=json | jq -r '.[].poolid')

CREATED=0; SKIPPED=0; ERRORS=0

# Lecture du CSV sur le descripteur 3 (les commandes pve* ne peuvent pas
# avaler de lignes) ; « || [[ -n ]] » garde la dernière ligne sans retour final
while IFS=';' read -r -u 3 NUM NOM PRENOM EMAIL || [[ -n "$NUM" ]]; do
    NUM=$(echo "$NUM" | tr -d '[:space:]')
    EMAIL=$(echo "$EMAIL" | tr -d '[:space:]')
    [[ -z "$NUM" || "$NUM" == \#* ]] && continue

    if ! [[ "$NUM" =~ ^[0-9]+$ ]]; then
        echo "⚠ Ligne ignorée (numéro invalide) : $NUM;$NOM;$PRENOM" | tee -a "$LOG_FILE"
        ERRORS=$((ERRORS+1)); continue
    fi

    # 10# évite l'interprétation octale de 08 / 09
    NUM=$(printf "%02d" "$((10#$NUM))")
    NEW_USER="${PREFIX}${NUM}${REALM}"
    NEW_POOL="${PREFIX}${NUM}"

    if [[ "$NEW_USER" == "$MODEL_USER" ]]; then
        echo "⚠ Ligne ignorée : $NEW_USER est le modèle" | tee -a "$LOG_FILE"
        continue
    fi

    echo "" | tee -a "$LOG_FILE"
    echo "━━━ $NEW_USER ($PRENOM $NOM) ━━━" | tee -a "$LOG_FILE"
    FAILED=0

    # 1. Utilisateur (avec ses groupes)
    echo -n "  [1/4] Utilisateur... " | tee -a "$LOG_FILE"
    if pveum user list --output-format=json | jq -e --arg u "$NEW_USER" '.[] | select(.userid==$u)' >/dev/null; then
        echo "existe, ignoré (groupes non modifiés)" | tee -a "$LOG_FILE"
        SKIPPED=$((SKIPPED+1))
    else
        ARGS=(--password "$PASSWORD" --firstname "$PRENOM" --lastname "$NOM")
        [[ -n "$EMAIL" ]] && ARGS+=(--email "$EMAIL")
        [[ -n "$GROUPS_LIST" ]] && ARGS+=(--groups "$GROUPS_LIST")
        if pveum user add "$NEW_USER" "${ARGS[@]}" >>"$LOG_FILE" 2>&1; then
            echo "✓" | tee -a "$LOG_FILE"
            CREATED=$((CREATED+1))
            echo "$NEW_USER;$NEW_POOL;$NOM;$PRENOM;$EMAIL" >> "$OUT_CSV"
        else
            echo "❌ (voir log)" | tee -a "$LOG_FILE"
            ERRORS=$((ERRORS+1)); continue
        fi
    fi

    # 2. Pool personnel
    echo -n "  [2/4] Pool... " | tee -a "$LOG_FILE"
    if grep -qxF "$NEW_POOL" <<<"$EXISTING_POOLS"; then
        echo "existe" | tee -a "$LOG_FILE"
    elif pvesh create /pools --poolid "$NEW_POOL" --comment "Pool de $PRENOM $NOM" >>"$LOG_FILE" 2>&1; then
        echo "✓" | tee -a "$LOG_FILE"
        EXISTING_POOLS+=$'\n'"$NEW_POOL"
    else
        echo "❌" | tee -a "$LOG_FILE"; FAILED=1
    fi

    # 3. ACL recopiées du modèle (datastores, réseau, templates...)
    echo -n "  [3/4] ACL modèle... " | tee -a "$LOG_FILE"
    ACL_KO=0
    for ACL in "${MODEL_ACLS[@]}"; do
        IFS='|' read -r P R PROP <<<"$ACL"
        pveum acl modify "$P" --users "$NEW_USER" --roles "$R" --propagate "$PROP" >>"$LOG_FILE" 2>&1 || ACL_KO=$((ACL_KO+1))
    done
    if [ $ACL_KO -eq 0 ]; then
        echo "✓ (${#MODEL_ACLS[@]})" | tee -a "$LOG_FILE"
    else
        echo "❌ $ACL_KO sur ${#MODEL_ACLS[@]} (voir log)" | tee -a "$LOG_FILE"; FAILED=1
    fi

    # 4. Droits sur le pool personnel
    echo -n "  [4/4] Droits pool ($POOL_ROLE)... " | tee -a "$LOG_FILE"
    if pveum acl modify "/pool/$NEW_POOL" --users "$NEW_USER" --roles "$POOL_ROLE" --propagate 1 >>"$LOG_FILE" 2>&1; then
        echo "✓" | tee -a "$LOG_FILE"
    else
        echo "❌" | tee -a "$LOG_FILE"; FAILED=1
    fi

    [ $FAILED -eq 1 ] && ERRORS=$((ERRORS+1))

done 3< <(sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$CSV" | tail -n +2)

echo ""
echo "=========================================="
echo "Créés : $CREATED · Ignorés : $SKIPPED · En erreur : $ERRORS"
echo "Log          : $LOG_FILE"
echo "Identifiants : $OUT_CSV (chmod 600)"
echo "=========================================="
[ $ERRORS -eq 0 ]
