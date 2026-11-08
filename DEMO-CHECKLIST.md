# Démo live du 20/11 — déroulé exact

Durée cible : 12–15 min. Tout se lance depuis **kali**, dans `~/pca-lab`. Mots de passe : `.secrets` (ne jamais l'afficher à l'écran).

## J-1 / H-30 min : démarrage et vérifications

1. Démarrer les VM dans l'ordre : **app01** (base + Odoo, ~1 min pour être healthy), **lb01**, puis kali.
   Ne pas mettre l'hôte en veille pendant la démo (une veille fige les VM ; au réveil Odoo tue ses workers pour `limit_time_real`).
2. Vérifier l'accès et l'état :
   ```bash
   cd ~/pca-lab
   ssh app01 true && ssh lb01 true && echo SSH-OK
   ./scenarios/reset_lab.sh          # attendu : "RESET OK: 4 containers healthy, 6/6 HAProxy servers UP"
   ./tools/check_phase4.sh | head -30   # health 200, cert OK, 301, en-têtes, 10/10/10, login, websocket 101
   ```
3. Préparer l'écran (4 zones) :
   - **A — Firefox** onglet 1 : `https://odoo.pca.lab` connecté en `vendeur1` (Ventes > Commandes). Cadenas vert (CA du lab installée).
   - **A — Firefox** onglet 2 : `http://lb01:8404/stats` (identifiants dans `.secrets`), rafraîchi toutes les 2 s.
   - **B — terminal 1** : sonde utilisateur `./scenarios/demo_watch.sh 900`  (une ligne verte toutes les 200 ms, avec le nœud).
   - **C — terminal 2** : logs LB `ssh lb01 'sudo journalctl -u haproxy -f -o cat | grep --line-buffered -E "is (UP|DOWN)| 429 | 50[0-9] "'`
   - **D — terminal 3** : commandes.
   - (option) Grafana `http://localhost:3000` si la phase 6 est démarrée (`monitoring/up.sh`).
4. Garder ouverts `RESULTS.md` et `SMCA-MAPPING.md` (chiffres et lien RTO/RPO).

## Déroulé (ce qu'on tape / ce qu'on montre / ce qu'on dit)

### 0. Architecture (1 min)
Montrer le schéma du `README.md`. Dire : 1 point d'entrée HTTPS, 3 nœuds Odoo identiques, état partagé (PostgreSQL + volume),
le LB apporte disponibilité, maintenance sans coupure, scalabilité, sécurité en bordure, observabilité.

### 1. Sécurité en bordure (2 min) — terminal D
```bash
curl -sI http://odoo.pca.lab/ | head -3                     # 301 -> https
curl -sI https://odoo.pca.lab/web/login | grep -iE 'strict|x-frame|x-content|set-cookie: SRV'
curl -s -o /dev/null -w '%{http_code}\n' https://odoo.pca.lab/web/database/manager   # 403 (bloqué au LB)
curl -m3 http://192.168.100.10:8069/web/health              # REFUSÉ : impossible de contourner le LB
./scenarios/s4_rate_limit.sh                                # ~1,5 min : 429 au-delà de 100 req/10 s, Odoo protégé
```
À montrer : terminal C affiche les `429` ; le verdict S4 (`100 x 200, 500 x 429, backend saw only 100`) ;
la connexion normale fonctionne juste après.

### 2. Disponibilité : panne d'un nœud (3 min)
1. Dans Firefox (onglet stats), repérer le nœud de la session navigateur (cookie `SRV`, ou ligne qui bouge).
   Supposons `odoo2`.
2. Terminal D :
   ```bash
   ssh app01 'sudo docker kill odoo-2'      # crash brutal
   ```
3. Montrer : stats → odoo2 passe **jaune puis rouge (DOWN)** en ~6 s ; terminal C : `Server be_odoo/odoo2 is DOWN` ;
   terminal B : **toutes les lignes restent vertes**, le champ `node=` change ; dans Firefox on continue à travailler
   (ouvrir une commande, créer un devis) **sans se reconnecter**.
4. Remettre :
   ```bash
   ssh app01 'sudo docker start odoo-2'     # UP de nouveau en ~8 s
   ```
Chiffres à citer (RESULTS.md, S1) : détection ≈ 6 s, 0 requête k6 en échec, session conservée.

### 3. Maintenance sans interruption : mise à jour progressive (2,5 min)
```bash
./scenarios/s2_rolling_update.sh
```
Pendant ce temps : montrer les stats (chaque nœud passe **DRAIN** (bleu) → **MAINT** (marron) → UP), le terminal B reste vert,
continuer à cliquer dans Odoo. Verdict attendu : `3 nodes replaced one by one ... 0 failed`.

### 4. Scalabilité (1 min, chiffres seulement — le test dure 4 min)
Ouvrir RESULTS.md section S3 et dire honnêtement : même VM 2 vCPU → pas de gain de débit (CPU saturé à 1 nœud) ;
avec des nœuds indépendants (émulés à 0,66 vCPU chacun) : 1 nœud s'effondre (503), 3 nœuds tiennent la même charge sans erreur.
Ajouter un nœud = une ligne `server` dans HAProxy, sans coupure.

### 5. Observabilité (1 min)
Stats (états, compteurs `Redis`/`Retr`, check status), logs enrichis (terminal C), éventuellement Grafana.
```bash
ssh lb01 'echo "show stat" | sudo socat stdio /run/haproxy/admin.sock' | cut -d, -f1,2,5,8,17,18,37 | column -ts,
```

### 6. Conclusion (30 s)
Montrer `SMCA-MAPPING.md` : bénéfice → objectif de continuité → preuve ; risques résiduels (lb01 seul, app01 seule, PostgreSQL
sans bascule auto) et leur traitement en production (keepalived, 2e hôte, Patroni).

## Si quelque chose se passe mal

| Symptôme | Action |
|----------|--------|
| Un nœud reste DOWN / MAINT / DRAIN | `./scenarios/reset_lab.sh` (remet tout `ready`, vide la stick-table) |
| Le navigateur reçoit 429 | `ssh lb01 'echo "clear table fe_https" \| sudo socat stdio /run/haproxy/admin.sock'` |
| Conteneur arrêté / unhealthy | `ssh app01 'cd /opt/pca-odoo && sudo docker compose up -d'` puis `./scenarios/reset_lab.sh` |
| Odoo répond 500 sur tous les nœuds après une veille de l'hôte | `ssh app01 'cd /opt/pca-odoo && sudo docker compose restart odoo-1 odoo-2 odoo-3'` |
| HAProxy ne répond plus | `ssh lb01 'sudo systemctl restart haproxy && systemctl is-active haproxy'` |
| Certificat refusé dans le navigateur | vérifier `odoo.pca.lab` dans `/etc/hosts` de kali ; la CA est `pki/ca.crt` (déjà installée dans Firefox/Chromium) |
| Plus de temps | sauter S2 en live et montrer `results/raw/results.tsv` + `RESULTS.md` |

Après la démo : `./scenarios/reset_lab.sh`.
