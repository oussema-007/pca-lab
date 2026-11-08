# Notes de soutenance — questions probables du jury

Réponses courtes et vérifiables. Les chiffres viennent de [`RESULTS.md`](RESULTS.md) ; la config est dans
`lb01/haproxy.cfg.tpl`, `app01/docker-compose.yml`, `app01/config/odoo.conf.tpl`.

### 1. Pourquoi `roundrobin` et pas `leastconn` pour Odoo ?
Les requêtes HTTP d'Odoo sont courtes et homogènes (RPC JSON de quelques dizaines de ms) et les 3 nœuds sont identiques.
Le round-robin répartit équitablement (mesuré : 10/10/10 sur 30 nouvelles sessions, 11/8/11 lors de la répétition — l'écart vient
des autres requêtes en cours et du `slowstart` d'un nœud récemment redémarré) et reste prévisible pour la démo.
`leastconn` sert quand les connexions durent longtemps ou ont des coûts très variables : c'est pourquoi **le backend
websocket `be_odoo_ws` est en `leastconn`** (connexions jusqu'à 1 h). De plus `maxconn 32` par serveur fait la file d'attente
dans HAProxy plutôt que dans Odoo, ce qui lisse déjà la charge.

### 2. Pourquoi une persistance par cookie alors que les sessions sont partagées ?
Les sessions sont dans le volume partagé `/var/lib/odoo/sessions` : la persistance n'est **pas nécessaire à la justesse**
(prouvé : une session créée sur odoo-1 est valide sur odoo-2 et odoo-3, et en S1 l'utilisateur change de nœud sans se reconnecter).
Le cookie `SRV` sert à : (a) garder les caches chauds d'un worker (registry, assets, ormcache) → meilleures latences ;
(b) rendre la démo lisible (on voit sur quel nœud on est) ; (c) permettre le `drain` propre en maintenance.
Si le nœud tombe, `option redispatch` ignore le cookie et envoie ailleurs. Options : `insert indirect nocache httponly secure`
= cookie posé par HAProxy, retiré avant Odoo, jamais mis en cache, inaccessible au JavaScript, envoyé seulement en HTTPS.

### 3. Que signifie `inter 2s fall 3 rise 2` pour le RTO ?
Un check toutes les 2 s ; 3 échecs consécutifs → DOWN ; 2 succès → UP. Pour un nœud qui **crashe** (port fermé, échec immédiat)
la détection est ≈ 3 × 2 s = 4–6 s (mesuré : 2,8–4,5 s après l'arrêt effectif du conteneur, ≈ 6 s après la commande, S1). Pour un nœud **figé** (process gelé), chaque check attend
`timeout check 2s` → ≈ 3 × (2 + 2) s ≈ 12 s (mesuré 10,3–12,7 s en S5). Retour en service : 2 checks OK ≈ 2–4 s après que
le conteneur répond (≈ 8 s après `docker start`), puis `slowstart 15s` remonte son poids progressivement car un worker Odoo
« froid » est lent (on a mesuré des requêtes de 12–15 s et un nœud qui oscillait DOWN/UP avant d'ajouter warm-up + slowstart). Mais surtout, **le RTO vu par l'utilisateur n'est pas le temps de détection** : pendant la détection,
les requêtes qui échouent sur le nœud mort sont rejouées ailleurs (retry + redispatch), d'où 0 erreur k6 en S1.
Compromis : un `inter` plus court détecte plus vite mais génère plus de checks et plus de faux positifs sous charge.

### 4. Que fait `option redispatch` (et `redispatch 1`, `retry-on`) ?
Sans redispatch, une requête avec cookie `SRV=odoo1` irait toujours vers odoo1, même mort. `option redispatch` autorise
HAProxy à choisir un autre serveur lors d'un retry. Par défaut il ne le fait qu'au **dernier** retry, après des pauses d'~1 s
sur le serveur mort : on a mesuré des trous de 2 s. `option redispatch 1` = changer de serveur à **chaque** retry.
`retries 3` + `retry-on conn-failure empty-response` : on rejoue si la connexion échoue **ou** si le serveur a fermé sans
renvoyer un seul octet (worker tué). `option http-buffer-request` est nécessaire pour pouvoir rejouer une requête POST.
Risque assumé : rejouer un POST dont la transaction aurait été validée juste avant le crash (fenêtre minime : Odoo commit à la fin).

### 5. Pourquoi `proxy_mode = True` ?
Derrière un reverse proxy, Odoo voit l'IP de HAProxy et du HTTP. `proxy_mode` lui fait lire `X-Forwarded-For`, `X-Forwarded-Proto`
et `X-Forwarded-Host` (posés par HAProxy) : bonne IP client dans les logs et la sécurité (blocage de login par IP),
URLs générées en `https://odoo.pca.lab`, cookies `secure` cohérents. À n'activer **que** derrière un proxy de confiance —
d'où le filtrage réseau qui empêche tout accès direct aux nœuds (sinon on pourrait forger `X-Forwarded-For`).

### 6. Pourquoi `/websocket` a son propre backend ?
Avec `workers > 0`, Odoo sert le bus temps réel (notifications, chat, mise à jour des vues) via un process gevent séparé sur
`gevent_port` 8072 ; les workers HTTP (8069) ne gèrent pas le websocket. Il faut donc router `/websocket` vers 8072/8172/8272.
Les connexions sont longues : `timeout tunnel 1h` (sinon coupure au `timeout client/server`) et `leastconn`. Mesuré : `HTTP 101`.

### 7. Pourquoi `list_db = False` et `dbfilter = ^pca_demo$` ?
`list_db = False` désactive le gestionnaire de bases (`/web/database/manager`) : plus de liste des bases, plus de création /
suppression / restauration / sauvegarde par le web, surface d'attaque majeure si le `admin_passwd` fuit. `dbfilter` épingle
la seule base autorisée. **Défense en profondeur** : HAProxy renvoie aussi 403 sur `/web/database/*` avant même Odoo (mesuré).
Le `admin_passwd` (master password) est aléatoire, dans `.secrets`.

### 8. Pourquoi filtrer les backends par pare-feu ?
Pour qu'on ne puisse **pas contourner le load balancer** : sinon un client parle directement à odoo-1, sans TLS, sans limite de débit,
sans logs centralisés, et peut forger `X-Forwarded-For` (proxy_mode). Seul lb01 peut joindre les ports Odoo, seul kali peut faire du SSH.
Point important découvert : **Docker contourne firewalld** pour les ports publiés (DNAT + FORWARD, les règles de zone ne filtrent
que INPUT). On l'a mesuré (kali obtenait 200 sur 8069) et corrigé avec la chaîne `DOCKER-USER` (service systemd `pca-docker-user`).
En plus, les ports ne sont publiés que sur l'IP du réseau lab, et PostgreSQL n'est pas publié du tout.

### 9. Comment se passe une mise à jour sans interruption ?
Runtime API HAProxy : `set server be_odoo/odooN state drain` (plus de nouveaux utilisateurs, les connexions en cours finissent) →
attendre 0 session courante → `state maint` (même les utilisateurs « collés » par cookie vont ailleurs) → recréer le conteneur →
attendre `healthy` → `state ready` → HAProxy le remet UP après 2 checks. Un nœud à la fois. Mesuré S2 : 3 nœuds remplacés,
0 requête en échec. C'est la « gestion du changement sans interruption » d'ISO 22301 / ITIL.

### 10. Le scale-out n'augmente pas le débit dans vos mesures. Alors à quoi sert-il ?
Honnêtement : les 3 nœuds tournent sur **la même VM à 2 vCPU**. Un seul nœud sature déjà le CPU (≈ 91–93 %) ; ajouter des
conteneurs sur le même CPU n'ajoute pas de capacité (mesuré ×0,85–0,91). La scalabilité horizontale paie quand chaque nœud apporte
son CPU (autre VM/hôte). On l'a émulé en limitant chaque conteneur à 0,66 vCPU : **1 nœud seul s'effondre** (checks en timeout →
HAProxy n'a plus de serveur → 503 en masse) alors que **3 nœuds servent la même charge sans erreur**. Le LB rend l'ajout d'un nœud
trivial (une ligne `server`, zéro interruption) — c'est ça le bénéfice architectural.

### 11. Pourquoi une limite à 100 requêtes / 10 s par IP ? Et l'exemption ?
On a mesuré une vraie session navigateur (login + web client à froid + liste des ventes) : 33 requêtes. 100/10 s laisse ×3 de marge
pour un humain, alors qu'un script de brute-force sur `/web/login` l'atteint en 2–3 s. Les requêtes en excès reçoivent 429 **de
HAProxy, sans toucher Odoo** (S4 : 600 requêtes envoyées, 100 arrivées au backend). Le test de charge doit mesurer l'appli, pas le
limiteur : il envoie un en-tête secret (valeur aléatoire dans `.secrets`, comparaison exacte), **supprimé avant Odoo** ; une valeur
devinée est limitée comme tout le monde (testé). Limite : derrière un NAT, plusieurs utilisateurs partagent une IP → en production
on suivrait aussi la session/le login.

### 12. Que se passe-t-il si lb01 tombe ? Et la base de données ?
Ce sont nos **points uniques de défaillance assumés** (voir `SMCA-MAPPING.md`) : lb01 seul, app01 seule VM, PostgreSQL sans bascule
automatique. En production : 2 HAProxy en **keepalived/VRRP** avec une VIP (bascule en ~1–3 s), nœuds Odoo sur ≥ 2 hôtes,
PostgreSQL en **Patroni** (+ etcd) ou réplique streaming avec promotion, filestore sur stockage partagé (NFS/Ceph/S3).
En phase 6 on montre une réplique streaming PostgreSQL et sa promotion manuelle : lag ≈ 1 ms, 0 ligne validée perdue au crash
du primaire, promotion 1,5–2,8 s, Odoo de nouveau servi 5,4–6,9 s après le crash (runbook scripté ; un humain mettrait des minutes).

### 13. Comment l'état est-il partagé entre les 3 nœuds ?
Tout l'état métier est dans PostgreSQL (une seule base), les fichiers joints et sessions dans un seul volume Docker monté
sur `/var/lib/odoo` par les 3 conteneurs. Les caches Odoo sont invalidés entre nœuds par la base (séquences de signalisation
`ir.registry` / `base_cache_signaling`), le bus temps réel passe par `LISTEN/NOTIFY` PostgreSQL. Les crons tournent sur les 3 nœuds
mais Odoo verrouille chaque job en base (`FOR UPDATE SKIP LOCKED`) : pas de double exécution.

### 14. Pourquoi terminer TLS sur le load balancer ?
Un seul endroit pour le certificat, la politique TLS (≥ 1.2, chiffrements AEAD, pas de tickets), HSTS et les en-têtes de sécurité ;
HAProxy peut lire le HTTP (cookies, chemins, en-têtes) pour router, limiter et journaliser. Le segment lb01 → app01 est en clair sur
le réseau lab isolé et filtré ; en production on rechiffrerait (TLS vers les backends) ou on utiliserait un réseau dédié.
La CA du lab est locale (clé jamais sortie de kali), le certificat a un SAN DNS + IP.

### 15. Comment prouvez-vous ce que vous avancez ? (observabilité)
Trois sources concordantes : (1) la **runtime API** (`show stat`) interrogée toutes les 250–500 ms par les scripts — c'est elle
qui donne les temps de détection ; (2) les **logs HAProxy** dans journald (format enrichi : serveur choisi, timers, état de terminaison,
cookie, débit du client, ID de requête) qui horodatent les transitions DOWN/UP ; (3) la page **stats** et les **métriques Prometheus**
(`/metrics`, Grafana en phase 6). Côté client, une sonde authentifiée toutes les 200 ms enregistre statut, latence et nœud servi.
Toutes les mesures brutes sont dans `results/raw/`, avec la commande exacte dans `RESULTS.md`.

---

### Questions bonus (si le temps le permet)
- **Pourquoi SELinux reste en enforcing avec Docker ?** On a activé `selinux-enabled` dans Docker (les conteneurs étaient en `spc_t`,
  non confinés) : ils tournent maintenant en `container_t` avec des catégories MCS par conteneur. Le fichier de config partagé est monté
  en `:z` (label partagé) et pas `:Z` (label privé → 217 refus AVC mesurés quand 3 conteneurs le lisent).
- **Pourquoi `/web/health` et pas une page de login comme health check ?** C'est la route prévue pour (Odoo 17), sans session ni base,
  très peu coûteuse. Limite : elle ne vérifie pas PostgreSQL (`?db_server_status=1` le ferait, mais une panne DB marquerait alors les
  3 nœuds DOWN en même temps, ce qui n'apporte rien au LB).
- **Docker stop vs crash ?** `docker stop` (arrêt propre) : 1 requête sur ~475 de la sonde a échoué au moment où Odoo ferme son socket
  (HAProxy 2.4.22 l'a vue mais ne l'a pas rejouée, les 3 autres l'ont été) ; `docker kill` (crash) : 0 échec. Pour une maintenance
  planifiée on draine d'abord (S2) → 0 échec.
